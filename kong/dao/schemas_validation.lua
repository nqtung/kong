local utils = require "kong.tools.utils"
local stringy = require "stringy"

local POSSIBLE_TYPES = {
  id = true,
  table = true,
  array = true,
  string = true,
  number = true,
  boolean = true,
  url = true,
  timestamp = true
}

local custom_types_validation = {
  ["id"] = function(v) return type(v) == "string" end,
  ["timestamp"] = function(v) return type(v) == "number" end,
  ["url"] = function(v)
    if v and type(v) == "string" then
      local parsed_url = require("socket.url").parse(v)
      return parsed_url and parsed_url.path and parsed_url.host and parsed_url.scheme
    end
  end,
  ["array"] = function(v) return utils.is_array(v) end
}

local function validate_type(field_type, value)
  if custom_types_validation[field_type] then
    return custom_types_validation[field_type](value)
  end
  return type(value) == field_type
end

local _M = {}

-- Validate a table against a given schema
-- @param  `t`         Entity to validate, as a table.
-- @param  `schema`    Schema against which to validate the entity.
-- @param  `options`
--           `dao_insert` A function called foe each field with a `dao_insert_value` property.
--           `is_update`  For an entity update, check immutable fields. Set to true.
-- @return `valid`     Success of validation. True or false.
-- @return `errors`    A list of encountered errors during the validation.
function _M.validate_entity(t, schema, options)
  if not options then options = {} end
  local errors

  if not options.partial_update and not options.full_update then
    for column, v in pairs(schema.fields) do
      -- [DEFAULT] Set default value for the field if given
      if t[column] == nil and v.default ~= nil then
        if type(v.default) == "function" then
          t[column] = v.default(t)
        else
          t[column] = v.default
        end
      end
      -- [INSERT_VALUE]
      if v.dao_insert_value and type(options.dao_insert) == "function" then
        t[column] = options.dao_insert(v)
      end
    end
  end

  -- Check the given table against a given schema
  for column, v in pairs(schema.fields) do
    -- [IMMUTABLE] check immutability of a field if updating
    if (options.partial_update or options.full_update) and t[column] ~= nil and v.immutable and not v.required then
      errors = utils.add_error(errors, column, column.." cannot be updated")
    end

    -- [TYPE] Check if type is valid. Boolean and Numbers as strings are accepted and converted
    if t[column] ~= nil and v.type ~= nil then
      local is_valid_type
      -- ALIASES: number, timestamp, boolean and array can be passed as strings and will be converted
      if type(t[column]) == "string" then
        t[column] = stringy.strip(t[column])
        if v.type == "number" or v .type == "timestamp" then
          t[column] = tonumber(t[column])
          is_valid_type = t[column] ~= nil
        elseif v.type == "boolean" then
          local bool = t[column]:lower()
          is_valid_type = bool == "true" or bool == "false"
          t[column] = bool == "true"
        elseif v.type == "array" then
          t[column] = stringy.strip(t[column]) == "" and {} or stringy.split(t[column], ",") -- Handling empty arrays
          for arr_k, arr_v in ipairs(t[column]) do
            t[column][arr_k] = stringy.strip(arr_v)
          end
          is_valid_type = validate_type(v.type, t[column])
        else -- if string
          is_valid_type = validate_type(v.type, t[column])
        end
      else
        is_valid_type = validate_type(v.type, t[column])
      end

      if not is_valid_type and POSSIBLE_TYPES[v.type] then
        errors = utils.add_error(errors, column, column.." is not a "..v.type)
      end
    end

    -- [ENUM] Check if the value is allowed in the enum.
    if t[column] ~= nil and v.enum then
      local found = false
      for _, allowed in ipairs(v.enum) do
        if allowed == t[column] then
          found = true
          break
        end
      end

      if not found then
        errors = utils.add_error(errors, column, string.format("\"%s\" is not allowed. Allowed values are: \"%s\"", t[column], table.concat(v.enum, "\", \"")))
      end
    end

    -- [REGEX] Check field against a regex if specified
    if t[column] ~= nil and v.regex then
      if not ngx.re.match(t[column], v.regex) then
        errors = utils.add_error(errors, column, column.." has an invalid value")
      end
    end

    -- [SCHEMA] Validate a sub-schema from a table or retrieved by a function
    if v.schema then
      local sub_schema, err
      if type(v.schema) == "function" then
        sub_schema, err = v.schema(t)
        if err then -- could not retrieve sub schema
          errors = utils.add_error(errors, column, err)
        end
      else
        sub_schema = v.schema
      end

      if sub_schema then
        -- Check for sub-schema defaults and required properties in advance
        if t[column] == nil then
          for sub_field_k, sub_field in pairs(sub_schema.fields) do
            if sub_field.default ~= nil then -- Sub-value has a default, be polite and pre-assign the sub-value
              t[column] = {}
            elseif sub_field.required then -- Only check required if field doesn't have a default
              errors = utils.add_error(errors, column, column.."."..sub_field_k.." is required")
            end
          end
        end

        if t[column] and type(t[column]) == "table" then
          -- Actually validating the sub-schema
          local s_ok, s_errors = _M.validate_entity(t[column], sub_schema, options)
          if not s_ok then
            for s_k, s_v in pairs(s_errors) do
              errors = utils.add_error(errors, column.."."..s_k, s_v)
            end
          end
        end
      end
    end

    if not options.partial_update or t[column] ~= nil then
      -- [REQUIRED] Check that required fields are set.
      -- Now that default and most other checks have been run.
      if v.required and (t[column] == nil or t[column] == "") then
        errors = utils.add_error(errors, column, column.." is required")
      end

      if type(v.func) == "function" and (errors == nil or errors[column] == nil) then
        -- [FUNC] Check field against a custom function
        -- only if there is no error on that field already.
        local ok, err, new_fields = v.func(t[column], t, column)
        if ok == false and err then
          errors = utils.add_error(errors, column, err)
        elseif new_fields then
          for k, v in pairs(new_fields) do
            t[k] = v
          end
        end
      end
    end
  end

  -- Check for unexpected fields in the entity
  for k in pairs(t) do
    if schema.fields[k] == nil then
      errors = utils.add_error(errors, k, k.." is an unknown field")
    end
  end

  if errors == nil and type(schema.self_check) == "function" then
    local ok, err = schema.self_check(schema, t, options.dao, (options.partial_update or options.full_update))
    if ok == false then
      return false, nil, err
    end
  end

  return errors == nil, errors
end

local digit = "[0-9a-f]"
local uuid_pattern = "^"..table.concat({ digit:rep(8), digit:rep(4), digit:rep(4), digit:rep(4), digit:rep(12) }, '%-').."$"
function _M.is_valid_uuid(uuid)
  return uuid and uuid:match(uuid_pattern) ~= nil
end

return _M
