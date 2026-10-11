// SPDX-License-Identifier: MIT
// Pure helpers for the phone launcher: settings merging and the rule that
// decides whether the bottom bar's text is an app search or a prompt for the
// coding agent.

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// Manifest defaults, overlaid with the plugin's entry in shell.json
// (`plugins: [{ "id": "omarchy-mobile.launcher", "agentName": "Codex", ... }]`).
function mergedSettings(defaults, config, pluginId) {
  var out = {}
  var base = isPlainObject(defaults) ? defaults : {}
  for (var key in base) out[key] = base[key]
  var plugins = isPlainObject(config) && Array.isArray(config.plugins) ? config.plugins : []
  for (var i = 0; i < plugins.length; i++) {
    var entry = plugins[i]
    if (!isPlainObject(entry) || entry.id !== pluginId) continue
    for (var k in entry) if (k !== "id") out[k] = entry[k]
  }
  return out
}

function argv(value, fallback) {
  if (Array.isArray(value)) return value.map(function(part) { return String(part) })
  if (typeof value === "string" && value.trim()) return value.trim().split(/\s+/)
  return fallback.slice()
}

function wordCount(query) {
  var text = String(query || "").trim()
  return text ? text.split(/\s+/).length : 0
}

// A short query that names an app is a search. Text reads as a prompt once it
// has enough words to be a sentence, ends like one, or matches no app at all.
function looksLikePrompt(query, appMatches, sentenceWords) {
  var text = String(query || "").trim()
  if (!text) return false
  if (wordCount(text) >= Math.max(2, sentenceWords || 3)) return true
  if (/[?.!]$/.test(text)) return true
  return appMatches === 0
}

// The argv that opens a terminal running the agent with the prompt as its
// first message: terminal... agent... prompt. The prompt stays one argument.
function agentArgv(terminal, agent, prompt) {
  return terminal.concat(agent, [String(prompt || "").trim()])
}

if (typeof module !== "undefined") {
  module.exports = {
    mergedSettings: mergedSettings,
    argv: argv,
    wordCount: wordCount,
    looksLikePrompt: looksLikePrompt,
    agentArgv: agentArgv
  }
}
