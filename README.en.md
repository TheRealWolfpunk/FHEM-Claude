[Deutsch](README.md) | [English](README.en.md)

# FHEM-Claude

Version: 1.3.2

FHEM module for integrating the Anthropic Claude AI API. Supports text queries, image analysis, smart home device control via voice command, and more – directly from within FHEM.

This module is a fork of https://github.com/ahlers2mi/FHEM-Gemini.

`98_Claude` has been specifically adapted for the German language. Therefore, the usage examples in this English README intentionally keep the original German example commands and phrases where that best reflects real-world usage.

### API Costs & Credits

This module uses Anthropic's prepaid system. By default, the model **claude-haiku-4-5** is configured because it is currently the most cost-effective Claude model and usually offers a very suitable balance between capability and ongoing cost for typical home automation requests.

As a rough guideline, for typical short status queries or simple switching commands with **claude-haiku-4-5**, you can often expect around **up to 3,000 requests per 5 USD**. In very minimal setups with a small context, even more may be possible; with larger device context, longer chat histories, or more complex tasks, significantly fewer may be possible.

Important: This is only a non-binding rough estimate and not a guarantee. Actual usage depends, among other things, on the size of your FHEM device list, the transmitted context, chat history, additional information such as `comment` or `<instanceName>_Instructions`, the model used, and the complexity of the requests.

Important in practice: If `localControlResolver` is active, many simple and unambiguous control commands are executed directly in FHEM locally. In those cases, no additional Claude API call is necessary. This noticeably saves tokens and therefore ongoing costs in day-to-day use, so the real number of possible commands per 5 USD can often turn out better in typical control scenarios than with purely API-based usage.

## Features

- 💬 Ask Claude text-based questions
- 🖼️ Analyze images (file path)
- 🗨️ Universal `chat` command for general questions, device status, and control
- 🏠 Control smart home devices via voice command
- 🏘️ Conveniently allow additional controllable devices by room using `controlRoom`
- ⚡ Claude hybrid mode (local mode) with local resolver and Claude fallback
- 🚀 Execute many simple commands directly locally without an additional API call
- 📋 Query and summarize device status
- 📊 Token usage visible via readings (`promptTokenCount`, `candidatesTokenCount`, `totalTokenCount`)
- 🧹 Configurable `readingBlacklist` with wildcard support for more compact contexts
- 📝 Optional `comment` device attribute as additional semantic description
- 🔄 Multi-turn chat history (optionally disableable)
- 🛡️ Whitelist-based device control (only explicitly allowed devices)

## Requirements

- FHEM installation (Perl-based)
- Anthropic Claude API key ([get one here - paid, see above](https://platform.claude.com))

## Installation

### First-time installation

```text
update all https://raw.githubusercontent.com/TheRealWolfpunk/FHEM-Claude/main/controls_Claude.txt
shutdown restart
```

### For automatic updates (together with `update all`)

```text
update add https://raw.githubusercontent.com/TheRealWolfpunk/FHEM-Claude/main/controls_Claude.txt
```

After that, the module will be updated automatically with every `update all`.

## Setup

### 1. Define the device

```text
define ClaudeAI Claude
```

### 2. Set the API key

```text
attr ClaudeAI apiKey YOUR-ANTHROPIC-CLAUDE-API-KEY
```

### 3. Optional: Choose a model

```text
attr ClaudeAI model claude-haiku-4-5
```

This is already the default and usually a very good choice for typical FHEM use cases. At the same time, **claude-haiku-4-5** is currently the most cost-effective available Claude model. Other available models: `claude-sonnet-4-6`, `claude-opus-4-6`

A current model overview is available here: https://platform.claude.com/docs/en/about-claude/models/overview

## Usage

### Ask a text question

```text
set ClaudeAI ask Wie wird das Wetter morgen in Berlin?
```

### Analyze an image

```text
set ClaudeAI askWithImage /opt/fhem/www/snapshot.jpg Was ist auf diesem Bild zu sehen?
```

Supported image formats: `jpg`/`jpeg`, `png`, `gif`, `webp`.

### Query device status

```text
attr ClaudeAI deviceList Lampe1,Heizung,Rolladen1
set ClaudeAI askAboutDevices Welche Geräte sind gerade eingeschaltet?
```

Alternatively, automatically include all devices in one or more rooms:

```text
attr ClaudeAI deviceRoom Wohnzimmer,Kueche
set ClaudeAI askAboutDevices Gib mir eine Zusammenfassung aller Geräte.
```

Using the wildcard `*` includes **all** devices defined in FHEM:

```text
attr ClaudeAI deviceList *
set ClaudeAI askAboutDevices Welche Geräte sind gerade aktiv?
```

### Control devices via voice command

```text
attr ClaudeAI controlList Lampe1,Heizung,Rolladen1
set ClaudeAI control Mach die Wohnzimmerlampe an
set ClaudeAI control Stelle die Heizung auf 21 Grad
set ClaudeAI control Fahre alle Rolläden runter
```

Controllable devices are taken from `controlList` as well as all devices in the
rooms specified in `controlRoom`.

Just like with `deviceList`, the wildcard `*` can also be used with `controlList`
to make all devices defined in FHEM controllable:

```text
attr ClaudeAI controlList *
set ClaudeAI control Schalte alle Lampen im Wohnzimmer aus
```

Alternatively, controllable devices can be enabled by room:

```text
attr ClaudeAI controlRoom Wohnzimmer,Kueche
set ClaudeAI control Schalte im Wohnzimmer das Licht aus
```

### Exclude specific readings and commands from the context

With `readingBlacklist`, technically less useful or very extensive readings and
command names can be filtered out of the context sent to Claude. This helps keep
the transmitted context more compact.

```text
attr ClaudeAI readingBlacklist R-* Wifi* battery
```

- the list is space-separated
- wildcards using `*` are supported
- the blacklist is applied to `askAboutDevices`, the `control` context, and
  `get_device_state`
- for `get_device_state` as well as in device and control contexts, only selected
  relevant readings are considered, not all existing readings indiscriminately
- in addition, there is an internal default blacklist for common technical
  entries that are usually not helpful for Claude

If the `comment` attribute is maintained on FHEM devices, it is also included as
an additional description in the device and control context.

In addition, an instance-specific attribute such as `ClaudeAI_Instructions` can
be used per Claude instance (for an instance named `ClaudeAI`). This attribute is
intended for device-specific instructions only for that Claude instance and is
also included in the device and control context.

Example:

```text
attr LampeWohnzimmer ClaudeAI_Instructions Die Lampe steht links neben dem Sofa und ist die Hauptbeleuchtung für den Raum.
```

This allows you to provide Claude with additional semantic hints per device
without overloading the general device attributes.

### Universal `chat` command

`chat` provides a single Telegram-/messenger-like entry point so there is no
need to distinguish between `ask`, `askAboutDevices`, and `control`.

```text
set ClaudeAI chat Wie warm ist es im Wohnzimmer?
set ClaudeAI chat Schalte bitte die Stehlampe ein
set ClaudeAI chat Was bedeutet die Fehlermeldung meiner Wallbox?
```

Behavior:
- if controllable devices are configured via `controlList` and/or `controlRoom`,
  `chat` is processed through the control logic
- the fork's Claude-specific features are preserved:
  local resolver, referential follow-up instructions, batch logic, and tool use
- additionally, existing device context from `deviceList`/`deviceRoom` is still
  included if configured; `chat` can therefore use control and general device
  context at the same time
- if no controllable devices are configured, `chat` behaves like a normal Claude
  request with optional device context

## Claude Hybrid Mode (Local Mode) with Local Resolver

If `localControlResolver` is enabled, the module works in hybrid mode:

1. **Local resolver first**
   - many simple and unambiguous control commands are executed directly in FHEM
   - in those cases, no additional Claude API call is triggered
   - this saves tokens and therefore ongoing costs in daily use
   - typical standard switching commands therefore usually respond very directly in practice

2. **Claude as fallback for more complex language**
   - complex, ambiguous, or more freely phrased instructions are still handled by Claude
   - this keeps voice control flexible without forcing simple commands through the API every time

The local resolver handles many typical standard switching commands directly in FHEM. This avoids unnecessary API calls in everyday use and helps keep the running cost of Claude in FHEM manageable. Claude remains available in the background for more complex language.

Enable or disable it:

```text
attr ClaudeAI localControlResolver 1
```

or

```text
attr ClaudeAI localControlResolver 0
```

With `1`, the local resolver is active.  
With `0`, every `control` command is handled completely through Claude.

### Typical advantages

- many simple standard commands are executed directly in FHEM
- no additional API call is needed for locally resolved commands
- this saves tokens and therefore ongoing costs in daily use
- Claude still remains available for more difficult cases

### Typical limitations

- the local resolver works deliberately conservatively
- it only handles commands that can be resolved safely and unambiguously
- free-form or very indirect language is still routed to the Claude fallback
- complex semantics, scene logic, or unclear target sets are deliberately not “guessed” locally

### Typical cases that often work locally

- alias match for exactly one device  
  z. B. `mach die Lavalampe an`
- unambiguous combinations of room + device type + simple switching command  
  z. B. `schalte die Lampen im Wohnzimmer ein`
- referential follow-up commands referring to the last target set  
  z. B. `du kannst sie wieder ausmachen`

### Typical cases that still go through Claude

- complex or free-form semantics  
  z. B. `mach es doch etwas gemütlicher`
- language that cannot be resolved unambiguously
- more complex value or parameter instructions
- cases where states first need to be checked or interpreted

In fallback mode, Claude automatically resolves alias names to internal FHEM names, can choose suitable `set` commands, and can also query a device's status independently if needed before sending a control command.

### Reset chat

```text
set ClaudeAI resetChat
```

### Show chat history

```text
get ClaudeAI chatHistory
```

## Attributes

| Attribute | Description | Default |
|---|---|---|
| `apiKey` | Anthropic Claude API key (required) | – |
| `model` | Claude model | `claude-haiku-4-5` |
| `timeout` | HTTP timeout in seconds | `30` |
| `systemPrompt` | Optional system prompt; longer prompts increase the transmitted context per request | – |
| `maxHistory` | Maximum number of chat messages; less history keeps the transmitted context smaller | `10` |
| `maxTokens` | Maximum response length; if the attribute is not set, fallback values are used depending on request type: `600` for `ask`/`askAboutDevices`, `300` for `control`/tool use | – |
| `disable` | Disable module (`0/1`) | `0` |
| `disableHistory` | Disable chat history (`0/1`); each request is treated as a standalone conversation | `0` |
| `promptCaching` | Enable prompt caching via Claude API (`0/1`); recurring prompts and contexts can then be processed more efficiently | `0` |
| `deviceContextMode` | Context for `askAboutDevices`: `compact` or `detailed`; `compact` keeps the context smaller and sends only status plus a small selection of important readings per device, `detailed` provides additional relevant details and attributes | `detailed` |
| `deviceList` | Comma-separated device list for `askAboutDevices`; `*` includes all FHEM devices | – |
| `deviceRoom` | Comma-separated room list; devices with a matching `room` attribute are automatically used for `askAboutDevices` | – |
| `controlContextMode` | Context for `control`: `compact` or `detailed`; `compact` keeps the context smaller and omits the additional output of typical available commands, `detailed` additionally provides typical available commands | `detailed` |
| `controlList` | Comma-separated list of devices Claude is allowed to control; can be combined with `controlRoom`. `*` enables all FHEM devices | – |
| `controlRoom` | Comma-separated room list; devices with a matching `room` attribute are automatically additionally considered controllable | – |
| `localControlResolver` | Enables the local resolver for Claude hybrid mode (`0/1`); simple and unambiguous `control` commands are executed directly in FHEM, more complex cases still go through Claude | `1` |
| `<instanceName>_Instructions` | Instance-specific device attribute per Claude instance, e.g. `ClaudeAI_Instructions`; adds device-specific instructions for exactly this Claude instance in the device and control context | – |
| `readingBlacklist` | Space-separated list of reading or command names that are not transmitted to Claude; wildcards such as `R-*` or `Wifi_*` are supported; applies to device/control context and `get_device_state`; additionally there is an internal default blacklist | – |
| `showAdvancedTokenReadings` | Enables or disables extended token/cache readings (`0/1`); default is `0`, meaning hidden. With `1`, additional technical cache/token details become visible as readings; with `0` or when the attribute is deleted, these extra readings are removed again | `0` |

## Readings

Token readings explained simply

In daily use, these three values are usually the most helpful:

- `promptTokenCount`: how much input context was sent to Claude, e.g. your question, chat history, system prompt, or device context
- `candidatesTokenCount`: how many tokens Claude generated for the actual response
- `totalTokenCount`: approximate total of a request from input and output; if Anthropic reports cache creation separately, that portion is additionally included here

This makes it easy to quickly estimate whether a lot of context was sent, the response was unusually long, or the overall request was relatively expensive.

Cache values such as `cacheCreationInputTokens` or `cacheReadInputTokens` are technical detail values from the Anthropic response and are usually only relevant for debugging or usage analysis in daily use. That is why they can be shown or hidden via `showAdvancedTokenReadings`.

| Reading | Description |
|---|---|
| `response` | Last text response from Claude (raw Markdown) |
| `responsePlain` | Last text response, Markdown syntax removed (plain text, ideal for Telegram, Notify) |
| `responseHTML` | Last text response, Markdown converted to HTML (ideal for tablet UI, web frontends) |
| `responseSSML` | Last text response, cleaned up for speech output and prepared as SSML |
| `state` | Current status (`initialized`, `requesting...`, `ok`, `error`, `disabled`) |
| `lastError` | Last error |
| `chatHistory` | Number of messages in the chat history |
| `lastCommand` | Last executed `set` command (e.g. `Lamp1 on`) |
| `lastCommandResult` | Result of the last `set` command (`ok` or error message) |
| `lastRequestModel` | Model name of the last request |
| `lastRequestType` | Type of the last request, e.g. `ask`, `askWithImage`, `askAboutDevices`, or `control` |
| `lastRequestWasLocal` | `1` for local `control` execution without Claude API, otherwise `0`. With the local resolver, the module explicitly sets this value to `1` |
| `lastApiCallUsedTools` | `1` if the last Claude API call used tool use, otherwise `0`. For local execution the value is explicitly `0` |
| `toolUseCount` | Number of `tool_use` blocks in the last Claude control response. For local execution the value is `0` |
| `toolSetDeviceCount` | Number of `set_device` tool calls in the last Claude control response |
| `toolGetDeviceStateCount` | Number of `get_device_state` tool calls in the last Claude control response. For local execution the value is `0` |
| `responseId` | Shows the Anthropic response ID. If an API response exceptionally contains no ID, `-` is shown here. For local execution, `-` is shown here as well |
| `responseType` | Shows the response type. For Anthropic responses this is usually `message`, for local execution `local` |
| `responseRole` | Shows the response role. For Anthropic responses this is usually `assistant`, for local execution likewise `assistant` |
| `stopReason` | Stop reason of the last Claude response. For local execution this is `local` |
| `stopSequence` | Shows the stop sequence at which Anthropic ended the response. If the response was not ended by a stop sequence or Anthropic sends no value, `-` is shown here |
| `stopDetails` | Shows additional details about the stop reason as JSON text. If Anthropic sends no additional details, `-` is shown here |
| `serviceTier` | Shows the service tier reported by Anthropic, for example `standard`. If Anthropic sends no value, `-` is shown here |
| `inferenceGeo` | Shows the inference region reported by Anthropic or a backend note such as `not_available`. If Anthropic sends no value, `-` is shown here |
| `promptTokenCount` | Number of tokens sent to Claude (input) |
| `candidatesTokenCount` | Number of tokens generated by Claude (response) |
| `totalTokenCount` | Total number of consumed tokens (input + output, optionally plus cache creation if provided) |
| `cacheCreationInputTokens` | Shows how many input tokens were written into a new prompt cache. `0` means: the field was provided, but no new cache portion was created for this request. Visible only when `showAdvancedTokenReadings` is enabled |
| `cacheReadInputTokens` | Shows how many input tokens were read from an existing prompt cache. `0` means: the field was provided, but no cache was used for this request. Visible only when `showAdvancedTokenReadings` is enabled |
| `cacheCreationEphemeral5mInputTokens` | Shows how many input tokens were written into a 5-minute cache. `0` means: the subfield was provided, but there was no corresponding cache portion for this request. If Anthropic does not provide this subfield, `-` is shown here. Visible only when `showAdvancedTokenReadings` is enabled |
| `cacheCreationEphemeral1hInputTokens` | Shows how many input tokens were written into a 1-hour cache. `0` means: the subfield was provided, but there was no corresponding cache portion for this request. If Anthropic does not provide this subfield, `-` is shown here. Visible only when `showAdvancedTokenReadings` is enabled |

## Notes on Costs and Liability

Use of the Anthropic Claude API is at your own responsibility. All costs resulting from API usage depend on your individual setup, the models used, the transmitted context, and your usage behavior, and may differ significantly in individual cases from the rough guidance mentioned in this README.

Neither the open-source community project FHEM nor its contributors nor the author of this module assume any warranty or liability for incurred API costs, unexpectedly high token usage, misconfigurations, unfavorable prompts, overly large or unnecessary context, errors in the module, changes to the external API, or any other circumstances that may lead to higher usage or additional costs.

It is the user's responsibility to choose the configuration carefully, monitor token usage via the available readings, and limit the transmitted context to what is necessary.

## License

This module is a community contribution and is licensed under the [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), in accordance with the FHEM license.
