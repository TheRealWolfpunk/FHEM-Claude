# FHEM-Gemini

FHEM-Modul zur Anbindung der Google Gemini AI API. Ermöglicht Textanfragen, Bildanalyse, Smart-Home-Gerätesteuerung per Sprachbefehl (Function Calling) und mehr – direkt aus FHEM heraus.

## Features

- 💬 Textfragen an Gemini stellen
- 🖼️ Bilder analysieren (Dateipfad)
- 🏠 Smart-Home-Geräte per Sprachbefehl steuern (Function Calling)
- 📋 Geräte-Status abfragen und zusammenfassen lassen
- 🔄 Multi-Turn Chat-Verlauf (optional deaktivierbar)
- 🛡️ Whitelist-basierte Gerätekontrolle (nur explizit freigegebene Geräte)

## Voraussetzungen

- FHEM-Installation (Perl-basiert)
- Google Gemini API Key ([hier kostenlos erhalten](https://aistudio.google.com/app/apikey))

## Installation

### Erstmalig laden

```
update all https://raw.githubusercontent.com/ahlers2mi/FHEM-Gemini/main/controls_Gemini.txt
shutdown restart
```

### Für automatische Updates (zusammen mit `update all`)

```
update add https://raw.githubusercontent.com/ahlers2mi/FHEM-Gemini/main/controls_Gemini.txt
```

Danach wird das Modul bei jedem `update all` automatisch mitaktualisiert.

## Einrichtung

### 1. Gerät definieren

```
define GeminiAI Gemini
```

### 2. API Key setzen

```
attr GeminiAI apiKey DEIN-GOOGLE-GEMINI-API-KEY
```

### 3. Optional: Modell wählen

```
attr GeminiAI model gemini-3.1-flash-lite-preview
```

Das ist bereits der Standard. Andere verfügbare Modelle: `gemini-2.0-flash`, `gemini-1.5-pro` usw.

## Verwendung

### Textfrage stellen

```
set GeminiAI ask Was ist das Wetter morgen in Berlin?
```

### Bild analysieren

```
set GeminiAI askWithImage /opt/fhem/www/snapshot.jpg Was ist auf diesem Bild zu sehen?
```

### Geräte-Status abfragen

```
attr GeminiAI deviceList Lampe1,Heizung,Rolladen1
set GeminiAI askAboutDevices Welche Geräte sind gerade eingeschaltet?
```

Alternativ alle Geräte eines Raums automatisch einbeziehen:

```
attr GeminiAI deviceRoom Wohnzimmer,Küche
set GeminiAI askAboutDevices Gib mir eine Zusammenfassung aller Geräte.
```

### Geräte per Sprachbefehl steuern (Function Calling)

```
attr GeminiAI controlList Lampe1,Heizung,Rolladen1
set GeminiAI control Mach die Wohnzimmerlampe an
set GeminiAI control Stelle die Heizung auf 21 Grad
set GeminiAI control Fahre alle Rolläden runter
```

Gemini löst Alias-Namen automatisch auf interne FHEM-Namen auf und wählt passende `set`-Befehle selbstständig aus. Nur Geräte aus `controlList` dürfen gesteuert werden.

### Chat zurücksetzen

```
set GeminiAI resetChat
```

### Chat-Verlauf anzeigen

```
get GeminiAI chatHistory
```

## Attribute

| Attribut | Beschreibung | Standard |
|---|---|---|
| `apiKey` | Google Gemini API Key (Pflicht) | – |
| `model` | Gemini Modell | `gemini-3.1-flash-lite-preview` |
| `maxHistory` | Maximale Anzahl Chat-Nachrichten | `20` |
| `systemPrompt` | Optionaler System-Prompt | – |
| `timeout` | HTTP Timeout in Sekunden | `30` |
| `disable` | Modul deaktivieren (0/1) | `0` |
| `disableHistory` | Chat-Verlauf deaktivieren (0/1); jede Anfrage wird als eigenständiges Gespräch behandelt | `0` |
| `deviceList` | Komma-getrennte Geräteliste für `askAboutDevices` | – |
| `deviceRoom` | Komma-getrennte Raumliste; alle Geräte mit passendem `room`-Attribut werden für `askAboutDevices` verwendet | – |
| `controlList` | Komma-getrennte Liste der Geräte, die Gemini steuern darf (Pflicht für `control`) | – |

## Readings

| Reading | Beschreibung |
|---|---|
| `response` | Letzte Textantwort von Gemini |
| `state` | Aktueller Status (`initialized`, `requesting...`, `ok`, `error`, `disabled`) |
| `lastError` | Letzter Fehler |
| `chatHistory` | Anzahl der Nachrichten im Chat-Verlauf |
| `lastCommand` | Letzter ausgeführter set-Befehl (z.B. `Lampe1 on`) |
| `lastCommandResult` | Ergebnis des letzten set-Befehls (`ok` oder Fehlermeldung) |

## Versionshistorie

| Version | Datum | Änderung |
|---|---|---|
| 2.4.0 | 2026-04-09 | Neues Attribut `disableHistory`: Chat-Verlauf optional deaktivieren |
| 2.3.0 | 2026-04-09 | `Gemini_BuildControlContext` gibt jetzt auch verfügbare set-Befehle aus |
| 2.2.1 | 2026-04-09 | Fix: Regex für verbotene Zeichen korrigiert |
| 2.2.0 | 2026-04-09 | Fix: Alias→Name-Mapping wird als `system_instruction` übergeben |
| 2.1.0 | 2026-04-09 | Neues Attribut `deviceRoom` |
| 2.0.2 | 2026-04-09 | Fix: gesamtes `content`-Objekt der Modellantwort im Chat speichern |
| 2.0.1 | 2026-04-09 | Standard-Modell auf `gemini-3.1-flash-lite-preview` aktualisiert |
| 2.0.0 | 2026-04-09 | Function Calling: neuer Befehl `control`, Attribut `controlList` |
| 1.3.0 | 2026-03-31 | Fix: UTF-8 Encoding für Readings vs. Chat-Verlauf getrennt behandelt |
| 1.2.0 | 2026-03-31 | `deviceContext` nur bei `askAboutDevices` mitschicken |
| 1.1.0 | 2026-03-31 | Fix: doppeltes UTF-8 Encoding in FHEM-Readings |
| 1.0.0 | 2026-03-31 | Initiale Version |

## Lizenz

Dieses Modul ist ein Community-Beitrag und steht unter der [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), entsprechend der FHEM-Lizenz.