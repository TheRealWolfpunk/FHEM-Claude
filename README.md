# FHEM-Claude

Version: 1.3.2

FHEM-Modul zur Anbindung der Anthropic Claude AI API. Ermöglicht Textanfragen, Bildanalyse, Smart-Home-Gerätesteuerung per Sprachbefehl und mehr – direkt aus FHEM heraus.

Dieses Modul ist ein Fork von https://github.com/ahlers2mi/FHEM-Gemini.

### API-Kosten & Credits

Dieses Modul nutzt das Prepaid-System von Anthropic. Standardmäßig ist das Modell **claude-haiku-4-5** hinterlegt, weil es aktuell das kostengünstigste Claude-Modell ist und für typische Hausautomations-Anfragen in der Regel ein sehr passendes Verhältnis aus Leistung und laufenden Kosten bietet.

Als grobe Orientierung für typische, eher kurze Statusabfragen oder einfache Schaltbefehle mit **claude-haiku-4-5** kann man häufig mit etwa **bis zu 3.000 Anfragen pro 5 $** rechnen. In sehr sparsamen Setups mit kleinem Kontext kann auch mehr möglich sein, bei größerem Gerätekontext, längeren Chat-Verläufen oder komplexeren Aufgaben aber auch deutlich weniger.

Wichtig: Diese Angabe ist nur eine unverbindliche Grobabschätzung und keine Zusage. Der tatsächliche Verbrauch hängt unter anderem vom Umfang deiner FHEM-Geräteliste, vom gesendeten Kontext, von Chat-Historie, Zusatzinformationen wie `comment` oder `<Instanzname>Instructions`, vom verwendeten Modell sowie von der Komplexität der Anfragen ab.

Wichtig für die Praxis: Wenn der `localControlResolver` aktiv ist, werden viele einfache und eindeutige Steuerbefehle direkt lokal in FHEM ausgeführt. Für diese Fälle ist kein zusätzlicher Claude-API-Aufruf nötig. Das spart im Alltag Tokens und damit laufende Kosten spürbar, sodass die reale Anzahl möglicher Befehle pro 5 $ in typischen Steuerungsszenarien oft eher besser ausfallen kann als bei rein API-basierter Nutzung.

## Features

- 💬 Textfragen an Claude stellen
- 🖼️ Bilder analysieren (Dateipfad)
- 🗨️ Universeller `chat`-Befehl für allgemeine Fragen, Geräte-Status und Steuerung
- 🏠 Smart-Home-Geräte per Sprachbefehl steuern
- 🏘️ Steuerbare Geräte zusätzlich bequem über `controlRoom` nach Räumen freigeben
- ⚡ Claude-Hybridbetrieb (Lokalmodus) mit lokalem Resolver und Claude-Fallback
- 🚀 Viele einfache Befehle direkt lokal ausführen, ohne zusätzlichen API-Call
- 📋 Geräte-Status abfragen und zusammenfassen lassen
- 📊 Tokenverbrauch über Readings sichtbar (`promptTokenCount`, `candidatesTokenCount`, `totalTokenCount`)
- 🧹 Konfigurierbare `readingBlacklist` mit Wildcard-Support für kompaktere Kontexte
- 📝 Optionales `comment`-Attribut der Geräte zusätzlich als semantische Beschreibung
- 🔄 Multi-Turn Chat-Verlauf (optional deaktivierbar)
- 🛡️ Whitelist-basierte Gerätekontrolle (nur explizit freigegebene Geräte)

## Voraussetzungen

- FHEM-Installation (Perl-basiert)
- Anthropic Claude API Key ([hier erhalten - kostenpflichtig, siehe oben](https://platform.claude.com))

## Installation

### Erstmalig laden

```text
update all https://raw.githubusercontent.com/TheRealWolfpunk/FHEM-Claude/main/controls_Claude.txt
shutdown restart
```

### Für automatische Updates (zusammen mit `update all`)

```text
update add https://raw.githubusercontent.com/TheRealWolfpunk/FHEM-Claude/main/controls_Claude.txt
```

Danach wird das Modul bei jedem `update all` automatisch aktualisiert.

## Einrichtung

### 1. Gerät definieren

```text
define ClaudeAI Claude
```

### 2. API Key setzen

```text
attr ClaudeAI apiKey DEIN-ANTHROPIC-CLAUDE-API-KEY
```

### 3. Optional: Modell wählen

```text
attr ClaudeAI model claude-haiku-4-5
```

Das ist bereits der Standard und für typische FHEM-Anwendungen meist eine sehr gute Wahl. Gleichzeitig ist **claude-haiku-4-5** aktuell das kostengünstigste verfügbare Claude-Modell. Andere verfügbare Modelle: `claude-sonnet-4-6`, `claude-opus-4-6`

Eine aktuelle Übersicht der Modelle gibt es hier: https://platform.claude.com/docs/en/about-claude/models/overview

## Verwendung

### Textfrage stellen

```text
set ClaudeAI ask Wie ist das Wetter morgen in Berlin?
```

### Bild analysieren

```text
set ClaudeAI askWithImage /opt/fhem/www/snapshot.jpg Was ist auf diesem Bild zu sehen?
```

Unterstützte Bildformate: `jpg`/`jpeg`, `png`, `gif`, `webp`.

### Geräte-Status abfragen

```text
attr ClaudeAI deviceList Lampe1,Heizung,Rolladen1
set ClaudeAI askAboutDevices Welche Geräte sind gerade eingeschaltet?
```

Alternativ alle Geräte eines Raums automatisch einbeziehen:

```text
attr ClaudeAI deviceRoom Wohnzimmer,Küche
set ClaudeAI askAboutDevices Gib mir eine Zusammenfassung aller Geräte.
```

Mit dem Wildcard `*` werden **alle** in FHEM definierten Geräte einbezogen:

```text
attr ClaudeAI deviceList *
set ClaudeAI askAboutDevices Welche Geräte sind gerade aktiv?
```

### Geräte per Sprachbefehl steuern

```text
attr ClaudeAI controlList Lampe1,Heizung,Rolladen1
set ClaudeAI control Mach die Wohnzimmerlampe an
set ClaudeAI control Stelle die Heizung auf 21 Grad
set ClaudeAI control Fahre alle Rolläden runter
```

Steuerbar sind Geräte aus `controlList` sowie zusätzlich alle Geräte aus den in
`controlRoom` eingetragenen Räumen.

Wie bei `deviceList` kann auch bei `controlList` der Wildcard `*` verwendet
werden, um alle in FHEM definierten Geräte steuerbar zu machen:

```text
attr ClaudeAI controlList *
set ClaudeAI control Schalte alle Lampen im Wohnzimmer aus
```

Alternativ können steuerbare Geräte auch raumbasiert freigegeben werden:

```text
attr ClaudeAI controlRoom Wohnzimmer,Küche
set ClaudeAI control Schalte im Wohnzimmer das Licht aus
```

### Readings und Befehle gezielt aus dem Kontext ausschließen

Mit `readingBlacklist` lassen sich technisch wenig hilfreiche oder sehr
umfangreiche Readings bzw. Befehlsnamen gezielt aus dem an Claude gesendeten
Kontext herausfiltern. Das hilft, den übertragenen Kontext kompakter zu halten.

```text
attr ClaudeAI readingBlacklist R-* Wifi_* battery
```

- die Liste ist leerzeichen-getrennt
- Wildcards mit `*` werden unterstützt
- die Blacklist wird auf `askAboutDevices`, den `control`-Kontext und
  `get_device_state` angewendet
- bei `get_device_state` sowie in Device- und Control-Kontexten werden nur
  ausgewählte relevante Readings berücksichtigt, nicht pauschal alle
  vorhandenen Readings
- zusätzlich gibt es eine interne Standard-Blacklist für typische technische
  Einträge, die für Claude meist wenig hilfreich sind

Wenn bei FHEM-Geräten das Attribut `comment` gepflegt ist, wird dieses außerdem
zusätzlich als Beschreibung in den Device- und Control-Kontext übernommen.

Zusätzlich kann pro Claude-Instanz ein instanzspezifisches Attribut wie
`ClaudeAIInstructions` verwendet werden (bei einer Instanz mit dem Namen
`ClaudeAI`). Dieses Attribut dient für gerätespezifische Anweisungen nur für
diese Claude-Instanz und wird zusätzlich in den Device- und Control-Kontext
übernommen.

Beispiel:

```text
attr LampeWohnzimmer ClaudeAIInstructions Die Lampe steht links neben dem Sofa und ist die Hauptbeleuchtung für den Raum.
```

Damit lassen sich Claude gezielt zusätzliche semantische Hinweise pro Gerät
geben, ohne die allgemeinen Device-Attribute zu überladen.

### Universeller `chat`-Befehl

Mit `chat` lässt sich ein einzelner Telegram-/Messenger-artiger Einstiegspunkt
verwenden, ohne zwischen `ask`, `askAboutDevices` und `control` unterscheiden zu
müssen.

```text
set ClaudeAI chat Wie warm ist es im Wohnzimmer?
set ClaudeAI chat Schalte bitte die Stehlampe ein
set ClaudeAI chat Was bedeutet die Fehlermeldung meiner Wallbox?
```

Verhalten:
- wenn steuerbare Geräte über `controlList` und/oder `controlRoom`
  konfiguriert sind, wird `chat` über die Control-Logik verarbeitet
- dabei bleiben die Claude-spezifischen Spezialitäten des Forks erhalten:
  lokaler Resolver, referenzielle Folgeanweisungen, Batch-Logik und Tool-Use
- zusätzlich wird vorhandener Gerätekontext aus `deviceList`/`deviceRoom`
  weiterhin mitgegeben, wenn er konfiguriert ist; `chat` kann also Steuerung
  und allgemeinen Gerätekontext gleichzeitig nutzen
- wenn keine steuerbaren Geräte konfiguriert sind, verhält sich `chat` wie
  eine normale Claude-Anfrage mit optionalem Gerätekontext

## Claude-Hybridbetrieb (Lokalmodus) mit lokalem Resolver

Wenn `localControlResolver` aktiviert ist, arbeitet das Modul im Hybridbetrieb:

1. **Lokaler Resolver zuerst**
   - viele einfache und eindeutige Steuerbefehle werden direkt in FHEM ausgeführt
   - dafür wird in diesen Fällen kein zusätzlicher Claude-API-Call ausgelöst
   - das spart im Alltag Tokens und damit laufende Kosten
   - typische Standardschaltungen reagieren dadurch in der Praxis meist sehr direkt

2. **Claude als Fallback für komplexere Sprache**
   - komplexe, mehrdeutige oder freier formulierte Anweisungen werden weiterhin von Claude verarbeitet
   - dadurch bleibt die Sprachsteuerung flexibel, ohne dass einfache Befehle immer über die API laufen müssen

Der lokale Resolver übernimmt viele typische Standardschaltungen direkt in FHEM. Das spart im Alltag unnötige API-Aufrufe und hilft dabei, die laufenden Kosten für Claude in FHEM überschaubar zu halten. Für komplexere Sprache bleibt Claude im Hintergrund weiterhin verfügbar.

Aktivieren oder deaktivieren:

```text
attr ClaudeAI localControlResolver 1
```

bzw.

```text
attr ClaudeAI localControlResolver 0
```

Bei `1` ist der lokale Resolver aktiv.  
Bei `0` läuft jeder `control`-Befehl vollständig über Claude.

### Typische Vorteile

- viele einfache Standardbefehle werden direkt in FHEM ausgeführt
- für lokal aufgelöste Befehle ist kein zusätzlicher API-Aufruf nötig
- das spart im Alltag Tokens und damit laufende Kosten
- Claude bleibt trotzdem für schwierigere Fälle verfügbar

### Typische Grenzen

- der lokale Resolver arbeitet bewusst konservativ
- er übernimmt nur Befehle, die sicher und eindeutig auflösbar sind
- freie oder sehr indirekte Sprache landet weiterhin beim Claude-Fallback
- komplexe Semantik, Szenenlogik oder unklare Zielmengen werden lokal bewusst nicht „erraten“

### Typische Fälle, die oft lokal funktionieren

- Alias-Treffer auf genau ein Gerät  
  z. B. `mach Stehlampe an`
- eindeutige Kombinationen aus Raum + Gerätetyp + einfachem Schaltkommando  
  z. B. `mach die Lampen im Wohnzimmer an`
- referenzielle Folgeanweisungen auf die letzte Zielmenge  
  z. B. `mach sie wieder aus`

### Typische Fälle, die weiterhin über Claude laufen

- komplexe oder freie Semantik  
  z. B. `mach es gemütlicher`
- nicht eindeutig auflösbare Sprache
- komplexere Wert- oder Parameteranweisungen
- Fälle, in denen zuerst Zustände geprüft oder interpretiert werden sollen

Claude löst im Fallback Alias-Namen automatisch auf interne FHEM-Namen auf, kann passende `set`-Befehle wählen und bei Bedarf auch den Status eines Geräts selbstständig abfragen, bevor ein Steuerbefehl abgesetzt wird.

### Chat zurücksetzen

```text
set ClaudeAI resetChat
```

### Chat-Verlauf anzeigen

```text
get ClaudeAI chatHistory
```

## Attribute

| Attribut | Beschreibung | Standard |
|---|---|---|
| `apiKey` | Anthropic Claude API Key (Pflicht) | – |
| `model` | Claude Modell | `claude-haiku-4-5` |
| `timeout` | HTTP Timeout in Sekunden | `30` |
| `systemPrompt` | Optionaler System-Prompt; längere Prompts erhöhen den mitgesendeten Kontext pro Anfrage | – |
| `maxHistory` | Maximale Anzahl Chat-Nachrichten; weniger Verlauf hält den mitgesendeten Kontext kleiner | `10` |
| `maxTokens` | Maximale Antwortlänge; ohne gesetztes Attribut werden je nach Anfrageart Fallback-Werte verwendet: `600` für `ask`/`askAboutDevices`, `300` für `control`/Tool Use | – |
| `disable` | Modul deaktivieren (`0/1`) | `0` |
| `disableHistory` | Chat-Verlauf deaktivieren (`0/1`); jede Anfrage wird als eigenständiges Gespräch behandelt | `0` |
| `promptCaching` | Prompt-Caching via Claude API aktivieren (`0/1`); wiederkehrende Prompts und Kontexte können dadurch effizienter verarbeitet werden | `0` |
| `deviceContextMode` | Kontext für `askAboutDevices`: `compact` oder `detailed`; `compact` hält den Kontext kleiner und sendet pro Gerät nur Status plus eine kleine Auswahl wichtiger Readings, `detailed` liefert zusätzlich mehr relevante Details und Attribute | `detailed` |
| `deviceList` | Komma-getrennte Geräteliste für `askAboutDevices`; `*` bezieht alle FHEM-Geräte ein | – |
| `deviceRoom` | Komma-getrennte Raumliste; Geräte mit passendem `room`-Attribut werden automatisch für `askAboutDevices` verwendet | – |
| `controlContextMode` | Kontext für `control`: `compact` oder `detailed`; `compact` hält den Kontext kleiner und verzichtet auf die zusätzliche Ausgabe typischer verfügbarer Befehle, `detailed` liefert zusätzlich typische verfügbare Befehle | `detailed` |
| `controlList` | Komma-getrennte Liste der Geräte, die Claude steuern darf; kann mit `controlRoom` kombiniert werden. `*` gibt alle FHEM-Geräte frei | – |
| `controlRoom` | Komma-getrennte Raumliste; Geräte mit passendem `room`-Attribut werden automatisch zusätzlich als steuerbar eingestuft | – |
| `localControlResolver` | Aktiviert den lokalen Resolver für den Claude-Hybridbetrieb (`0/1`); einfache und eindeutige `control`-Befehle werden direkt in FHEM ausgeführt, komplexere Fälle laufen weiter über Claude | `1` |
| `<Instanzname>Instructions` | Instanzspezifisches Geräteattribut pro Claude-Instanz, z. B. `ClaudeAIInstructions`; ergänzt gerätespezifische Anweisungen für genau diese Claude-Instanz im Device- und Control-Kontext | – |
| `readingBlacklist` | Leerzeichen-getrennte Liste von Reading- oder Befehlsnamen, die nicht an Claude übermittelt werden; Wildcards wie `R-*` oder `Wifi_*` werden unterstützt; gilt für Device-/Control-Kontext und `get_device_state`; zusätzlich existiert eine interne Standard-Blacklist | – |
| `showAdvancedTokenReadings` | Schaltet erweiterte Token-/Cache-Readings ein oder aus (`0/1`); Standard ist `0`, also ausgeblendet. Bei `1` werden zusätzliche technische Cache-/Token-Details als Readings sichtbar, bei `0` oder beim Löschen des Attributs werden diese zusätzlichen Readings wieder entfernt | `0` |

## Readings

Token-Readings einfach erklaert

Im Alltag helfen diese drei Werte am meisten:

- `promptTokenCount`: wie viel Eingabe-Kontext an Claude geschickt wurde, z. B. deine Frage, Chat-Verlauf, System-Prompt oder Geraetekontext
- `candidatesTokenCount`: wie viele Tokens Claude fuer die eigentliche Antwort erzeugt hat
- `totalTokenCount`: grobe Gesamtsumme einer Anfrage aus Input und Output; falls Anthropic Cache-Erzeugung separat ausweist, wird dieser Anteil hier zusaetzlich mit eingerechnet

Damit laesst sich schnell einschaetzen, ob eher viel Kontext gesendet wurde, die Antwort ungewoehnlich lang war oder die gesamte Anfrage insgesamt teuer war.

Die Cache-Werte wie `cacheCreationInputTokens` oder `cacheReadInputTokens` sind technische Detailwerte aus der Anthropic-Antwort und im Alltag meist nur fuer Debugging oder Verbrauchsanalyse interessant. Deshalb koennen sie ueber `showAdvancedTokenReadings` ein- oder ausgeblendet werden.

| Reading | Beschreibung |
|---|---|
| `response` | Letzte Textantwort von Claude (Roh-Markdown) |
| `responsePlain` | Letzte Textantwort, Markdown-Syntax entfernt (reiner Text, ideal für Telegram, Notify) |
| `responseHTML` | Letzte Textantwort, Markdown in HTML konvertiert (ideal für Tablet-UI, Web-Frontends) |
| `responseSSML` | Letzte Textantwort, für Sprachausgabe bereinigt und als SSML aufbereitet |
| `state` | Aktueller Status (`initialized`, `requesting...`, `ok`, `error`, `disabled`) |
| `lastError` | Letzter Fehler |
| `chatHistory` | Anzahl der Nachrichten im Chat-Verlauf |
| `lastCommand` | Letzter ausgeführter `set`-Befehl (z. B. `Lampe1 on`) |
| `lastCommandResult` | Ergebnis des letzten `set`-Befehls (`ok` oder Fehlermeldung) |
| `lastRequestModel` | Modellname des letzten Requests |
| `lastRequestType` | Typ des letzten Requests, z. B. `ask`, `askWithImage`, `askAboutDevices` oder `control` |
| `lastRequestWasLocal` | `1` bei lokaler `control`-Ausführung ohne Claude-API, sonst `0`. Bei lokalem Resolver setzt das Modul diesen Wert explizit auf `1` |
| `lastApiCallUsedTools` | `1`, wenn der letzte Claude-API-Call Tool Use verwendet hat, sonst `0`. Bei lokaler Ausführung steht der Wert explizit auf `0` |
| `toolUseCount` | Anzahl der im letzten Claude-Control-Response enthaltenen `tool_use`-Blöcke. Bei lokaler Ausführung ist der Wert `0` |
| `toolSetDeviceCount` | Anzahl der im letzten Claude-Control-Response enthaltenen `set_device`-Toolaufrufe |
| `toolGetDeviceStateCount` | Anzahl der im letzten Claude-Control-Response enthaltenen `get_device_state`-Toolaufrufe. Bei lokaler Ausführung ist der Wert `0` |
| `responseId` | Zeigt die Anthropic-Antwort-ID. Wenn bei einer API-Antwort ausnahmsweise keine ID geliefert wird, steht hier `-`. Bei lokaler Ausführung steht hier ebenfalls `-` |
| `responseType` | Zeigt den Antworttyp. Bei Anthropic-Antworten ist das normalerweise `message`, bei lokaler Ausführung `local` |
| `responseRole` | Zeigt die Rolle der Antwort. Bei Anthropic-Antworten ist das normalerweise `assistant`, bei lokaler Ausführung ebenfalls `assistant` |
| `stopReason` | Stop-Grund der letzten Claude-Antwort. Bei lokaler Ausführung steht hier `local` |
| `stopSequence` | Zeigt die Stop-Sequenz, an der Anthropic die Antwort beendet hat. Wenn die Antwort nicht wegen einer Stop-Sequenz beendet wurde oder Anthropic keinen Wert sendet, steht hier `-` |
| `stopDetails` | Zeigt zusätzliche Details zum Stoppgrund als JSON-Text. Wenn Anthropic keine Zusatzdetails sendet, steht hier `-` |
| `serviceTier` | Zeigt den von Anthropic gemeldeten Service-Tier, zum Beispiel `standard`. Wenn Anthropic keinen Wert sendet, steht hier `-` |
| `inferenceGeo` | Zeigt die von Anthropic gemeldete Inferenz-Region oder einen Backend-Hinweis wie `not_available`. Wenn Anthropic keinen Wert sendet, steht hier `-` |
| `promptTokenCount` | Anzahl der an Claude gesendeten Tokens (Input) |
| `candidatesTokenCount` | Anzahl der von Claude generierten Tokens (Antwort) |
| `totalTokenCount` | Gesamtsumme der verbrauchten Tokens (Input + Output, optional zzgl. Cache-Erzeugung falls geliefert) |
| `cacheCreationInputTokens` | Zeigt, wie viele Input-Tokens in einen neuen Prompt-Cache geschrieben wurden. `0` bedeutet: Das Feld wurde geliefert, aber für diesen Request wurde kein neuer Cache-Anteil erzeugt. Sichtbar nur bei aktiviertem `showAdvancedTokenReadings` |
| `cacheReadInputTokens` | Zeigt, wie viele Input-Tokens aus einem vorhandenen Prompt-Cache gelesen wurden. `0` bedeutet: Das Feld wurde geliefert, aber für diesen Request wurde kein Cache genutzt. Sichtbar nur bei aktiviertem `showAdvancedTokenReadings` |
| `cacheCreationEphemeral5mInputTokens` | Zeigt, wie viele Input-Tokens in einen 5-Minuten-Cache geschrieben wurden. `0` bedeutet: Das Unterfeld wurde geliefert, aber es gab fuer diesen Request keinen entsprechenden Cache-Anteil. Wenn Anthropic dieses Unterfeld nicht liefert, steht hier `-`. Sichtbar nur bei aktiviertem `showAdvancedTokenReadings` |
| `cacheCreationEphemeral1hInputTokens` | Zeigt, wie viele Input-Tokens in einen 1-Stunden-Cache geschrieben wurden. `0` bedeutet: Das Unterfeld wurde geliefert, aber es gab fuer diesen Request keinen entsprechenden Cache-Anteil. Wenn Anthropic dieses Unterfeld nicht liefert, steht hier `-`. Sichtbar nur bei aktiviertem `showAdvancedTokenReadings` |

## Hinweise zu Kosten und Haftung

Die Nutzung der Anthropic-Claude-API erfolgt auf eigene Verantwortung. Sämtliche durch die API-Nutzung entstehenden Kosten hängen von deinem individuellen Setup, den verwendeten Modellen, dem übermittelten Kontext sowie deinem Nutzungsverhalten ab und können im Einzelfall deutlich von den im README genannten Groborientierungen abweichen.

Weder das Open-Source-Community-Projekt FHEM noch dessen Mitwirkende oder der Autor dieses Moduls übernehmen eine Gewähr oder Haftung für entstehende API-Kosten, unerwartet hohen Tokenverbrauch, Fehlkonfigurationen, ungünstige Prompts, zu großen oder unnötigen Kontext, Fehler im Modul, Veränderungen an der externen API oder sonstige Umstände, die zu höherem Verbrauch oder zusätzlichen Kosten führen.

Es liegt in der Verantwortung des Nutzers, die Konfiguration sorgfältig zu wählen, den Tokenverbrauch über die vorhandenen Readings zu beobachten und den eingesetzten Kontext auf das notwendige Maß zu begrenzen.

## Lizenz

Dieses Modul ist ein Community-Beitrag und steht unter der [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), entsprechend der FHEM-Lizenz.
