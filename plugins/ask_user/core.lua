-- Interactive questions use Bone 3's transport-level ask mechanism. Any
-- client can answer them; this plugin asks them in the terminal prompt
-- and in a desktop window.
--
-- An answer is a string (older clients; multi-select values comma-separated)
-- or a table: { value, label, index } for a pick, { values, labels } for
-- multi-select (with custom = true when one is typed), { value, custom = true }
-- for a typed answer. Typing your own answer is always possible. "cancelled"
-- (or nil, when the turn is cancelled) stops asking.
local function question_spec(q, index, total)
  local out = { kind = "ask_user", text = q.question or q.text or "Question", index = index, total = total }
  out.type = q.type or (q.options and "single_select" or "text_input")
  out.options = q.options or {}
  return out
end

local ANSWER_FIELDS = { "value", "values", "label", "labels", "index", "custom" }

bone.tool.register({
  name = "ask_user",
  description = "Ask one or more questions and return the user's answers. "
    .. "The user can always type their own answer instead of picking an option.",
  parameters = {
    type = "object",
    properties = {
      questions = {
        type = "array", minItems = 1,
        items = {
          type = "object",
          properties = {
            question = { type = "string" },
            type = { type = "string", enum = { "single_select", "multi_select", "text_input" } },
            options = {
              type = "array",
              items = {
                anyOf = {
                  { type = "string" },
                  { type = "object", properties = {
                    label = { type = "string" }, value = { type = "string" }, description = { type = "string" },
                  }, required = { "label" } },
                },
              },
            },
          },
          required = { "question" },
        },
      },
    },
    required = { "questions" },
  },
  needs_approval = false,
  run = function(args)
    if type(args.questions) ~= "table" or #args.questions == 0 then
      return nil, "questions must contain at least one question"
    end
    local answers = {}
    for i, q in ipairs(args.questions) do
      if type(q) ~= "table" or type(q.question) ~= "string" then
        return nil, "question " .. tostring(i) .. " must have question text"
      end
      local spec = question_spec(q, i, #args.questions)
      local answer = bone.ask(spec)
      if answer == nil or answer == "cancelled" or (type(answer) == "table" and answer.cancelled) then
        return { cancelled = true, answers = answers, cancelled_at = i }
      end
      local entry = { question = q.question, type = spec.type }
      if type(answer) == "table" then
        for _, k in ipairs(ANSWER_FIELDS) do
          entry[k] = answer[k]
        end
      else
        entry.value = answer
      end
      answers[#answers + 1] = entry
    end
    return { cancelled = false, answers = answers }
  end,
})
