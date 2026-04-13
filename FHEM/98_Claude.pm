##############################################################################
# 98_Claude.pm
#
# FHEM Modul fuer Anthropic Claude AI
#
# Funktionen:
#   - Text-Anfragen an Claude senden
#   - Bilder (Base64 oder Dateipfad) senden
#   - Chat-Verlauf (Multi-Turn) beibehalten
#   - Chat zuruecksetzen
#   - FHEM-Geraete per Tool Use steuern
#
# Attribute:
#   apiKey         - Anthropic API Key (Pflicht)
#   model          - Claude Modell (Standard: claude-haiku-4-5)
#   maxHistory     - Maximale Anzahl Chat-Nachrichten (Standard: 10);
#                    weniger Verlauf haelt den mitgesendeten Kontext kleiner
#   maxTokens      - Maximale Antwortlaenge; ohne gesetztes Attribut werden
#                    je nach Anfrageart Fallback-Werte verwendet:
#                    600 fuer ask/askAboutDevices, 300 fuer control/Tool Use.
#                    Kleinere Werte begrenzen die Antwortlaenge und den
#                    zu erwartenden Tokenverbrauch
#   systemPrompt   - Optionaler System-Prompt; laengere Prompts erhoehen den
#                    mitgesendeten Kontext pro Anfrage
#   timeout        - HTTP Timeout in Sekunden (Standard: 30)
#   promptCaching  - Prompt-Caching via Claude API aktivieren (0/1);
#                    wiederkehrende Prompts und Kontexte koennen dadurch
#                    effizienter verarbeitet werden
#   deviceContextMode  - Kontext fuer askAboutDevices: compact oder detailed;
#                        compact haelt den Kontext kleiner, detailed liefert
#                        mehr Informationen
#   controlContextMode - Kontext fuer control: compact oder detailed;
#                        compact haelt den Kontext kleiner, detailed liefert
#                        mehr Informationen
#   deviceList     - Komma-getrennte Liste der Geraete fuer askAboutDevices
#   deviceRoom     - Komma-getrennte Raumliste; Geraete mit passendem room-Attribut
#                    werden automatisch fuer askAboutDevices verwendet
#   controlList    - Komma-getrennte Liste der Geraete, die Claude steuern darf
#   localControlResolver - Aktiviert den lokalen Resolver fuer den
#                    Claude-Hybridbetrieb (Lokalmodus) (0/1); einfache und
#                    eindeutige control-Befehle werden direkt in FHEM
#                    ausgefuehrt. Dafuer ist in diesen Faellen kein
#                    zusaetzlicher Claude-API-Aufruf noetig, was im Alltag
#                    Tokens und damit laufende Kosten sparen kann.
#                    Komplexere Faelle laufen weiterhin ueber Claude
#   readingBlacklist - Leerzeichen-getrennte Liste von Reading-/Befehlsnamen,
#                      die nicht an Claude uebermittelt werden; Wildcards (*)
#                      werden unterstuetzt
#   disableHistory - Chat-Verlauf deaktivieren (0/1); jede Anfrage wird als eigenstaendiges Gespraech behandelt
#
# Set-Befehle:
#   ask <Frage>                    - Textfrage stellen
#   askWithImage <Pfad> <Frage>    - Bild + Frage senden
#   askAboutDevices [<Frage>]      - Geraete-Statusabfrage
#   control <Anweisung>            - Claude steuert Geraete via Tool Use
#   resetChat                      - Chat-Verlauf loeschen
#
# Lesewerte (Readings):
#   response           - Letzte Antwort von Claude (Roh-Markdown)
#   responsePlain      - Letzte Antwort, Markdown bereinigt (reiner Text)
#   responseHTML       - Letzte Antwort, Markdown in HTML konvertiert
#   responseSSML       - Letzte Antwort, fuer Sprachausgabe bereinigt (SSML)
#   state              - Aktueller Status
#   lastError          - Letzter Fehler
#   chatHistory        - Anzahl der Nachrichten im Verlauf
#   lastCommand        - Letzter ausgefuehrter set-Befehl
#   lastCommandResult  - Ergebnis des letzten set-Befehls
#
##############################################################################

# Versionshistorie:
# 1.2.0 - 2026-04-13  Neu: readingBlacklist-Attribut mit Wildcard-Support
#                          fuer Device-/Control-Kontext und get_device_state;
#                          zusaetzlich wird das comment-Attribut von Geraeten
#                          in Device- und Control-Kontext uebernommen
# 1.1.0 - 2026-04-12  Neu: Claude-Hybridbetrieb (Lokalmodus) mit
#                          localControlResolver; viele einfache und
#                          eindeutige Steuerbefehle werden lokal direkt
#                          in FHEM ausgefuehrt, komplexe oder
#                          mehrdeutige Anweisungen laufen weiterhin
#                          ueber Claude
# 1.0.7 - 2026-04-12  Perf/Fix: Control-Prompts und ToolResult-Runden weiter
#                          komprimiert; effektive Control-History dynamisch
#                          begrenzt; Batch-Kontext bei mehrstufigem Tool-Use
#                          wird erst nach Abschluss der Session finalisiert,
#                          um Zielmengen-Fehler zu vermeiden
# 1.0.6 - 2026-04-12  Fix: Folgeanweisungen mit Pronomen robuster gemacht;
#                          letzte Steueraktion wird als Batch gemerkt und
#                          Anweisungen werden lokal vor dem API-Call auf
#                          die Zielmenge umgeschrieben und ausgefuehrt
# 1.0.5 - 2026-04-12  Fix/Perf: Control-Requests gegen leere Messages und
#                          Parameter abgesichert; Control-Antworten
#                          standardmaessig verkuerzt; zusaetzliche Debug-Logs
#                          fuer Referenzkontext und Tool-Use integriert
# 1.0.4 - 2026-04-12  Perf: Tokenverbrauch weiter reduziert; kleinere Defaults fuer
#                          maxHistory/maxTokens, optionales Prompt-Caching,
#                          kompaktere Tool-Definitionen, sowie optionale
#                          sparsame/ausfuehrliche Kontexte fuer askAboutDevices
#                          und control
# 1.0.3 - 2026-04-11  Neu: Reading responseSSML fuer Sprachausgabe ergaenzt
# 1.0.2 - 2026-04-11  Perf: Tokenverbrauch fuer Hausautomation reduziert;
#                          askAboutDevices-, control- und get_device_state-
#                          Kontexte auf kompakte, aber praxistaugliche
#                          Kerninformationen begrenzt
# 1.0.1 - 2026-04-11  Fix: Tool-Use/Tool-Result-Verarbeitung fuer Anthropic
#                          korrigiert; mehrere tool_use-Bloecke werden jetzt
#                          gesammelt beantwortet und unvollstaendige historische
#                          Tool-Turns vor API-Requests bereinigt
# 1.0.0 - 2026-04-11  Neu: Forked from 98_Gemini.pm; Umstellung von Google Gemini API
#                          auf Anthropic Claude API; Modulname, Doku, Endpunkte,
#                          Request/Response-Handling und Function Calling auf
#                          Claude Tool Use angepasst

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use MIME::Base64;

my $MODULE_VERSION = '1.2.0';

sub Claude_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}      = 'Claude_Define';
    $hash->{UndefFn}    = 'Claude_Undefine';
    $hash->{SetFn}      = 'Claude_Set';
    $hash->{GetFn}      = 'Claude_Get';
    $hash->{AttrFn}     = 'Claude_Attr';
    $hash->{AttrList}   =
        'apiKey ' .
        'model ' .
        'maxHistory:5,10,20,50,100 ' .
        'maxTokens ' .
        'timeout ' .
        'disable:0,1 ' .
        'disableHistory:0,1 ' .
        'promptCaching:0,1 ' .
        'deviceContextMode:compact,detailed ' .
        'controlContextMode:compact,detailed ' .
        'localControlResolver:0,1 ' .
        'readingBlacklist:textField-long ' .
        'deviceList:textField-long ' .
        'controlList:textField-long ' .
        'deviceRoom:textField-long ' .
        'systemPrompt:textField-long ' .
        $readingFnAttributes;

    foreach my $existingDeviceName (keys %defs) {
        if ($defs{$existingDeviceName}{TYPE} eq 'Claude') {
            $defs{$existingDeviceName}{VERSION} = $MODULE_VERSION;
        }
    }

    return undef;
}

sub Claude_Define {
    my ($hash, $def) = @_;
    my @args = split('[ \t]+', $def);

    return "Usage: define <name> Claude" if (@args < 2);

    my $name = $args[0];
    $hash->{NAME}        = $name;
    $hash->{CHAT}        = [];
    $hash->{VERSION}     = $MODULE_VERSION;

    readingsSingleUpdate($hash, 'state',             'initialized', 1);
    readingsSingleUpdate($hash, 'response',          '-',           0);
    readingsSingleUpdate($hash, 'responsePlain',     '-',           0);
    readingsSingleUpdate($hash, 'responseHTML',      '-',           0);
    readingsSingleUpdate($hash, 'responseSSML',      '-',           0);
    readingsSingleUpdate($hash, 'chatHistory',       0,             0);
    readingsSingleUpdate($hash, 'lastError',         '-',           0);
    readingsSingleUpdate($hash, 'lastCommand',       '-',           0);
    readingsSingleUpdate($hash, 'lastCommandResult', '-',           0);
    $hash->{LAST_CONTROLLED_DEVICES} = [];
    $hash->{LAST_CONTROL_BATCH}      = undef;

    if (!defined AttrVal($name, 'localControlResolver', undef)) {
        CommandAttr(undef, "$name localControlResolver 1");
    }

    Log3 $name, 3, "Claude ($name): Defined";
    return undef;
}

sub Claude_Undefine {
    my ($hash, $name) = @_;
    return undef;
}

sub Claude_Attr {
    my ($cmd, $name, $attr, $value) = @_;
    if ($attr eq 'timeout') {
        return "timeout must be a positive number" unless ($value =~ /^\d+$/ && $value > 0);
    }
    if ($attr eq 'maxTokens') {
        return "maxTokens must be a positive number" unless ($value =~ /^\d+$/ && $value > 0);
    }
    return undef;
}

sub Claude_Set {
    my ($hash, $name, $cmd, @args) = @_;

    return "\"set $name\" needs at least one argument" unless defined($cmd);

    if ($cmd eq 'ask') {
        return "Usage: set $name ask <Frage>" unless @args;
        my $question = join(' ', @args);
        Claude_SendRequest($hash, $question, undef, undef);
        return undef;

    } elsif ($cmd eq 'askWithImage') {
        return "Usage: set $name askWithImage <Bildpfad> <Frage>" unless @args >= 2;
        my $imagePath = $args[0];
        my $question  = join(' ', @args[1..$#args]);
        return "Bilddatei nicht gefunden: $imagePath" unless -f $imagePath;
        Claude_SendRequest($hash, $question, $imagePath, undef);
        return undef;

    } elsif ($cmd eq 'askAboutDevices') {
        my $question      = @args ? join(' ', @args) : 'Gib mir eine Zusammenfassung aller Geraete und ihres aktuellen Status.';
        my $deviceContext = Claude_BuildDeviceContext($hash);
        Claude_SendRequest($hash, $question, undef, $deviceContext);
        return undef;

    } elsif ($cmd eq 'control') {
        return "Usage: set $name control <Anweisung>" unless @args;
        my $controlList = AttrVal($name, 'controlList', '');
        return "Fehler: Attribut controlList ist nicht gesetzt" unless $controlList;
        my $instruction = join(' ', @args);
        Claude_SendControl($hash, $instruction);
        return undef;

    } elsif ($cmd eq 'resetChat') {
        $hash->{CHAT} = [];
        $hash->{LAST_CONTROLLED_DEVICES} = [];
        $hash->{LAST_CONTROL_BATCH}      = undef;
        readingsSingleUpdate($hash, 'chatHistory', 0, 1);
        readingsSingleUpdate($hash, 'state', 'chat reset', 1);
        Log3 $name, 3, "Claude ($name): Chat-Verlauf zurueckgesetzt";
        return undef;

    } else {
        return "Unknown argument $cmd, choose one of ask:textField askWithImage:textField askAboutDevices:textField control:textField resetChat:noArg";
    }
}

sub Claude_Get {
    my ($hash, $name, $cmd, @args) = @_;

    if ($cmd eq 'chatHistory') {
        my $history = $hash->{CHAT};
        my $output  = "Chat-Verlauf (" . scalar(@$history) . " Eintraege):\n";
        $output    .= "-" x 60 . "\n";

        for my $i (0..$#$history) {
            my $msg  = $history->[$i];
            my $role = $msg->{role} eq 'user' ? 'Du' : 'Claude';
            my $text = Claude_MessageToDisplayText($msg);
            $output .= sprintf("[%02d] %s: %s\n", $i+1, $role, $text);
        }
        return $output;
    }

    return "Unknown argument $cmd, choose one of chatHistory:noArg";
}

##############################################################################
# Hilfsfunktion: Nachricht fuer Anzeige aufbereiten
##############################################################################
sub Claude_MessageToDisplayText {
    my ($msg) = @_;
    return '' unless $msg && ref($msg) eq 'HASH';

    my $content = $msg->{content};
    return '' unless defined $content;

    if (!ref($content)) {
        return $content;
    }

    return '' unless ref($content) eq 'ARRAY';

    my @partsText;
    for my $part (@$content) {
        next unless ref($part) eq 'HASH';
        if (($part->{type} // '') eq 'text') {
            push @partsText, $part->{text} if exists $part->{text};
        } elsif (($part->{type} // '') eq 'image') {
            push @partsText, '[Bild]';
        } elsif (($part->{type} // '') eq 'tool_use') {
            my $toolName = $part->{name} // 'tool';
            push @partsText, "[ToolUse:$toolName]";
        } elsif (($part->{type} // '') eq 'tool_result') {
            push @partsText, '[ToolResult]';
        }
    }

    return join(' ', @partsText);
}

##############################################################################
# Hilfsfunktion: Chat-Verlauf begrenzen
##############################################################################
sub Claude_TrimHistory {
    my ($hash, $maxHistory) = @_;
    return unless $hash && ref($hash) eq 'HASH';
    return unless exists $hash->{CHAT} && ref($hash->{CHAT}) eq 'ARRAY';

    $maxHistory = int($maxHistory // 0);
    $maxHistory = 1 if $maxHistory < 1;

    # Verlauf hart auf die konfigurierte Anzahl Eintraege begrenzen
    while (scalar(@{$hash->{CHAT}}) > $maxHistory) {
        shift @{$hash->{CHAT}};
    }

    # Claude-Konversationen muessen sinnvoll mit einer User-Nachricht beginnen.
    # Fuehrende Assistant-Nachrichten werden deshalb abgeschnitten.
    while (@{$hash->{CHAT}} && $hash->{CHAT}[0]{role} ne 'user') {
        shift @{$hash->{CHAT}};
    }
}

##############################################################################
# Hilfsfunktion: Claude API Request Header
##############################################################################
sub Claude_RequestHeaders {
    my ($apiKey) = @_;

    return
        "Content-Type: application/json\r\n" .
        "Accept: application/json\r\n" .
        "anthropic-version: 2023-06-01\r\n" .
        "x-api-key: $apiKey";
}

##############################################################################
# Hilfsfunktion: URL fuer Claude Messages API
##############################################################################
sub Claude_ApiUrl {
    return 'https://api.anthropic.com/v1/messages';
}

##############################################################################
# Hauptfunktion: Anfrage an Claude API senden
##############################################################################
sub Claude_SendRequest {
    my ($hash, $question, $imagePath, $deviceContext) = @_;
    my $name = $hash->{NAME};

    # Modul deaktiviert? Dann keine Anfrage ausfuehren
    if (AttrVal($name, 'disable', 0)) {
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
        return;
    }

    my $apiKey = AttrVal($name, 'apiKey', '');
    if (!$apiKey) {
        readingsSingleUpdate($hash, 'lastError', 'Kein API Key gesetzt (attr apiKey)', 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): Kein API Key konfiguriert!";
        return;
    }

    my $model      = AttrVal($name, 'model',      'claude-haiku-4-5');
    my $timeout    = AttrVal($name, 'timeout',    30);
    my $maxHistory = int(AttrVal($name, 'maxHistory', 10));
    my $maxTokens  = int(AttrVal($name, 'maxTokens',  600));

    Log3 $name, 4, "Claude ($name): Verwende Modell $model";

    # Claude erwartet Inhalte als content-Array mit Text- und optionalen Bild-Bloecken
    my @content;

    if ($imagePath) {
        my $mimeType = Claude_GetMimeType($imagePath);
        if (!$mimeType) {
            readingsSingleUpdate($hash, 'lastError', "Nicht unterstuetztes Bildformat: $imagePath (erlaubt: jpg, jpeg, png, gif, webp)", 1);
            readingsSingleUpdate($hash, 'state', 'error', 1);
            Log3 $name, 2, "Claude ($name): Nicht unterstuetztes Bildformat: $imagePath";
            return;
        }
        open(my $fh, '<', $imagePath) or do {
            readingsSingleUpdate($hash, 'lastError', "Kann Bild nicht lesen: $imagePath", 1);
            readingsSingleUpdate($hash, 'state', 'error', 1);
            return;
        };
        binmode($fh);
        local $/;
        my $imageData   = <$fh>;
        close($fh);
        my $base64Image = encode_base64($imageData, '');

        push @content, {
            type   => 'image',
            source => {
                type       => 'base64',
                media_type => $mimeType,
                data       => $base64Image
            }
        };
        Log3 $name, 4, "Claude ($name): Bild geladen: $imagePath ($mimeType)";
    }

    push @content, {
        type => 'text',
        text => $question
    };

    # Benutzer-Nachricht in den lokalen Verlauf uebernehmen
    push @{$hash->{CHAT}}, {
        role    => 'user',
        content => \@content
    };

    # Verlauf auf maximale Laenge begrenzen und sicherstellen,
    # dass kein ungueltiger Assistant-Turn am Anfang steht
    Claude_TrimHistory($hash, $maxHistory);

    # Optional kann der Verlauf fuer API-Requests deaktiviert werden.
    # Dann wird nur die letzte Nachricht an Claude geschickt.
    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend = $disableHistory ? [ $hash->{CHAT}[-1] ] : $hash->{CHAT};

    # systemPrompt und optionaler deviceContext werden zu einem
    # gemeinsamen System-Text fuer Claude zusammengebaut
    my $systemPrompt = AttrVal($name, 'systemPrompt', '');
    my $fullSystem   = '';
    $fullSystem .= $systemPrompt  if $systemPrompt;
    $fullSystem .= "\n\n"         if $systemPrompt && $deviceContext;
    $fullSystem .= $deviceContext if $deviceContext;

    # Aufbau des Claude-Messages-Requests.
    # Anders als bei Gemini liegen System-Prompt und Nachrichten
    # in getrennten Feldern.
    my %requestBody = (
        model      => $model,
        max_tokens => $maxTokens,
        messages   => $messagesToSend
    );

    $requestBody{system} = $fullSystem if $fullSystem ne '';
    $requestBody{cache_control} = { type => 'ephemeral' } if AttrVal($name, 'promptCaching', 0);

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        pop @{$hash->{CHAT}};
        return;
    }

    Log3 $name, 4, "Claude ($name): Anfrage " . $jsonBody;

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => Claude_ApiUrl(),
        timeout  => $timeout,
        method   => 'POST',
        header   => Claude_RequestHeaders($apiKey),
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Claude_HandleResponse,
    });

    return undef;
}

##############################################################################
# Callback: Antwort von Claude verarbeiten
##############################################################################
sub Claude_HandleResponse {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        readingsSingleUpdate($hash, 'lastError', "HTTP Fehler: $err", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): HTTP Fehler: $err";
        pop @{$hash->{CHAT}};
        return;
    }

    utf8::downgrade($data, 1);

    my $result = eval { decode_json($data) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Parse Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): JSON Parse Fehler: $@";
        pop @{$hash->{CHAT}};
        return;
    }

    if (exists $result->{model}) {
        Log3 $name, 4, "Claude ($name): API meldet Modell " . $result->{model};
    }

    if (exists $result->{error}) {
        my $errType = $result->{error}{type}    // 'unknown_error';
        my $errMsg  = $result->{error}{message} // 'Unbekannter API Fehler';
        readingsSingleUpdate($hash, 'lastError', "API Fehler ($errType): $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): API Fehler ($errType): $errMsg";
        pop @{$hash->{CHAT}};
        return;
    }

    # Claude liefert die eigentliche Antwort als Liste von content-Bloecken
    my $contentBlocks = $result->{content} // [];
    my $responseUnicode = '';
    my %contentTypes;
    for my $part (@$contentBlocks) {
        next unless ref($part) eq 'HASH';
        my $type = $part->{type} // 'unknown';
        $contentTypes{$type}++;
        $responseUnicode .= $part->{text} if ($type eq 'text' && exists $part->{text});
    }

    if (!$responseUnicode) {
        my $stopReason = $result->{stop_reason} // 'UNKNOWN';
        my $types = %contentTypes ? join(', ', sort keys %contentTypes) : 'none';
        my $errMsg = "Claude-Antwort enthielt keinen Textblock (stop_reason: $stopReason, content types: $types)";
        readingsSingleUpdate($hash, 'lastError', $errMsg, 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "Claude ($name): $errMsg";
        pop @{$hash->{CHAT}};
        return;
    }

    # Assistant-Antwort vollstaendig fuer Multi-Turn-Gespraeche speichern
    push @{$hash->{CHAT}}, {
        role    => 'assistant',
        content => $contentBlocks
    };

    my $responseForReading = $responseUnicode;
    utf8::encode($responseForReading) if utf8::is_utf8($responseForReading);

    my $responsePlain = Claude_MarkdownToPlain($responseUnicode);
    utf8::encode($responsePlain) if utf8::is_utf8($responsePlain);

    my $responseHTML = Claude_MarkdownToHTML($responseUnicode);
    utf8::encode($responseHTML) if utf8::is_utf8($responseHTML);

    my $responseSSML = Claude_MarkdownToSSML($responseUnicode);
    utf8::encode($responseSSML) if utf8::is_utf8($responseSSML);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',      $responseForReading);
    readingsBulkUpdate($hash, 'responsePlain', $responsePlain);
    readingsBulkUpdate($hash, 'responseHTML',  $responseHTML);
    readingsBulkUpdate($hash, 'responseSSML',  $responseSSML);
    readingsBulkUpdate($hash, 'chatHistory',   scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',         'ok');
    readingsBulkUpdate($hash, 'lastError',     '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "Claude ($name): Antwort erhalten (" . length($responseUnicode) . " Zeichen)";
    return undef;
}

##############################################################################
# Hilfsfunktion: Markdown in reinen Text konvertieren
##############################################################################
sub Claude_MarkdownToPlain {
    my ($text) = @_;
    return '' unless defined $text;

    $text =~ s/```[^\n]*\n(.*?)```/$1/gms;
    $text =~ s/\*\*(.+?)\*\*/$1/gs;
    $text =~ s/__(.+?)__/$1/gs;
    $text =~ s/\*(.+?)\*/$1/gs;
    $text =~ s/_(.+?)_/$1/gs;
    $text =~ s/`(.+?)`/$1/gs;
    $text =~ s/^#{1,6}\s+(.+)$/$1/gm;
    $text =~ s/^[\-\*]\s+(.+)$/$1/gm;
    $text =~ s/<a[^>]*>(.+?)<\/a>/$1/gsi;
    $text =~ s/^(?:---|\*\*\*)\s*$//gm;

    return $text;
}

##############################################################################
# Hilfsfunktion: Markdown in HTML konvertieren
##############################################################################
sub Claude_MarkdownToHTML {
    my ($text) = @_;
    return '' unless defined $text;

    $text =~ s/```[^\n]*\n(.*?)```/<pre><code>$1<\/code><\/pre>/gms;
    $text =~ s/\*\*(.+?)\*\*/<b>$1<\/b>/gs;
    $text =~ s/__(.+?)__/<b>$1<\/b>/gs;
    $text =~ s/\*(.+?)\*/<i>$1<\/i>/gs;
    $text =~ s/_(.+?)_/<i>$1<\/i>/gs;
    $text =~ s/`(.+?)`/<code>$1<\/code>/gs;
    $text =~ s/^#{6}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{5}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{4}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{3}\s+(.+)$/<h5>$1<\/h5>/gm;
    $text =~ s/^#{2}\s+(.+)$/<h4>$1<\/h4>/gm;
    $text =~ s/^#\s+(.+)$/<h3>$1<\/h3>/gm;
    $text =~ s/((?:^[\-\*]\s+.+\n?)+)/my $block = $1; $block =~ s{^[\-\*]\s+(.+)$}{<li>$1<\/li>}gm; "<ul>$block<\/ul>"/gme;
    $text =~ s/^(?:---|\*\*\*)\s*$/<hr>/gm;
    $text =~ s/\n(?!<(?:ul|\/ul|li|\/li|h[3-6]|\/h[3-6]|pre|\/pre|hr))/<br>\n/g;

    return $text;
}

##############################################################################
# Hilfsfunktion: Antwort fuer Sprachausgabe in SSML umwandeln
##############################################################################
sub Claude_MarkdownToSSML {
    my ($text) = @_;
    return '' unless defined $text;

    $text =~ s/\r\n/\n/g;
    $text =~ s/\r/\n/g;
    $text =~ s/\\n/\n/g;
    $text =~ s/\n\s*\n+/\n/g;

    $text =~ s/[\x{1F300}-\x{1FAFF}]//g;
    $text =~ s/[\x{2600}-\x{27BF}]//g;
    $text =~ s/[\x{FE0F}\x{200D}]//g;
    $text =~ s/\s+\)/)/g;

    $text =~ s/\*\*([^*]*)\*\*/$1/g;
    $text =~ s/\*([^*]*)\*/$1/g;
    $text =~ s/__([^_]*)__/$1/g;
    $text =~ s/_([^_]*)_/$1/g;
    $text =~ s/`[^`]*`//g;
    $text =~ s/#{1,6}\s*//g;

    my @lines = split(/\n/, $text);
    my @result;

    foreach my $line (@lines) {
        $line =~ s/^\s*[-*•]\s+//;
        $line =~ s/^\s+|\s+$//g;
        next unless length($line);
        $line =~ s/^(\d+)\.\s+/$1. /;
        $line .= '.' unless $line =~ /[.!?,;:]$/ || $line =~ /\d+\.\d+$/;
        push @result, $line;
    }

    $text = join(' ', @result);
    $text =~ s/\n/ /g;
    $text =~ s/\s{2,}/ /g;
    $text =~ s/\.\s*\././g;
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/&/ und /g;
    $text =~ s/\// und /g;
    $text =~ s/\s{2,}/ /g;

    my @sentences = split(/(?<=[.!?])\s+/, $text);
    my @output;

    foreach my $sentence (@sentences) {
        $sentence =~ s/^\s+|\s+$//g;
        next unless length($sentence);

        if ($sentence =~ /^[^.]+:\s*\d+\s+\w+/) {
            $sentence =~ s/:\s*(.+)$/. $1/;
            $sentence .= '.' unless $sentence =~ /[.!?]$/;
        }

        push @output, $sentence;
    }

    $text = join(' ', @output);
    $text =~ s/\s+,/,/g;
    $text =~ s/:\././g;
    $text =~ s/\s{2,}/ /g;
    $text =~ s/^\s+|\s+$//g;

    return "<speak>$text</speak>";
}

##############################################################################
# Hilfsfunktion: MIME-Typ anhand Dateiendung bestimmen
##############################################################################
sub Claude_GetMimeType {
    my ($filePath) = @_;

    my $ext = '';
    if ($filePath =~ /\.([^.]+)$/) {
        $ext = lc($1);
    }

    my %mimeTypes = (
        'jpg'  => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'png'  => 'image/png',
        'gif'  => 'image/gif',
        'webp' => 'image/webp',
    );

    return $mimeTypes{$ext};
}

##############################################################################
# Hilfsfunktionen fuer Blacklist von Readings/Befehlen
##############################################################################
sub Claude_GetBlacklist {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @default = qw(
        associatedWith eventTypes .associatedWith .eventTypes
        localicons cmdIcon devStateIcon icon userReadings
        stateFormat room_map IODev .mseclog
        .computedReadings .updateHint .sortby
        DEF FUUID FVERSION VERSION
        OldValue OLDREADINGS CHANGED NOTIFYDEV
        NR NTFY_ORDER
        lastcmd Heap LoadAvg Uptime Wifi_*
    );

    my $attr = AttrVal($name, 'readingBlacklist', '');
    my @custom = grep { defined $_ && $_ ne '' } split(/\s+/, $attr);

    my %seen;
    return grep { !$seen{$_}++ } (@default, @custom);
}

sub Claude_GlobMatch {
    my ($str, $pattern) = @_;
    return 0 unless defined $str && defined $pattern;

    return 1 if $pattern eq '*';

    my @parts = split(/\*/, $pattern, -1);
    my $leadingWildcard  = ($pattern =~ /^\*/) ? 1 : 0;
    my $trailingWildcard = ($pattern =~ /\*$/) ? 1 : 0;

    my $prefix = $leadingWildcard  ? '' : shift @parts;
    my $suffix = $trailingWildcard ? '' : pop @parts;

    return 0 if length($prefix) && substr($str, 0, length($prefix)) ne $prefix;
    return 0 if length($suffix) && substr($str, -length($suffix)) ne $suffix;

    my $pos = length($prefix);
    for my $part (@parts) {
        next if $part eq '';
        my $idx = index($str, $part, $pos);
        return 0 if $idx < 0;
        $pos = $idx + length($part);
    }

    return 1;
}

sub Claude_IsBlacklisted {
    my ($name, @patterns) = @_;
    return 0 unless defined $name;

    for my $pattern (@patterns) {
        next unless defined $pattern && $pattern ne '';
        return 1 if Claude_GlobMatch($name, $pattern);
    }

    return 0;
}

##############################################################################
# FHEM Device-Kontext fuer Claude aufbauen
##############################################################################
sub Claude_GetRelevantReadings {
    my ($devName, %opts) = @_;
    return () unless defined $devName && $devName ne '' && exists $main::defs{$devName};

    my $max = $opts{max} // 5;
    my $traits = Claude_GetDeviceTraits($devName);
    my $dev = $main::defs{$devName};
    my $readingsHash = $dev->{READINGS} || {};
    my %available = map { $_ => 1 } keys %{$readingsHash};

    my @preferred = ('state');

    if ($traits->{light}) {
        push @preferred, qw(pct bri brightness power reachable);
    }
    if ($traits->{cover}) {
        push @preferred, qw(position pct state motor direction);
    }
    if ($traits->{climate}) {
        push @preferred, qw(desired-temp measured-temp temperature humidity mode valveposition actuator);
    }
    if ($traits->{sensor}) {
        push @preferred, qw(temperature humidity battery contact motion presence luminance illumination);
    }
    if ($traits->{switchable} && !$traits->{light}) {
        push @preferred, qw(power energy consumption battery);
    }

    push @preferred, qw(battery batteryLevel signal strength reachable);
    my %seen;
    my @result;

    for my $reading (@preferred) {
        next if $seen{$reading}++;
        next unless $available{$reading};
        push @result, $reading;
        last if @result >= $max;
    }

    if (@result < $max) {
        my @dynamicPriority = sort {
            (($a =~ /temp|humid|battery|contact|motion|presence|state|pct|bri|power|energy|mode|position/i) ? 0 : 1)
            <=>
            (($b =~ /temp|humid|battery|contact|motion|presence|state|pct|bri|power|energy|mode|position/i) ? 0 : 1)
            ||
            $a cmp $b
        } grep { !$seen{$_} && $_ ne 'state' } keys %available;

        for my $reading (@dynamicPriority) {
            push @result, $reading;
            last if @result >= $max;
        }
    }

    return @result;
}

sub Claude_BuildDeviceContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %seen;
    my @devices;

    my $deviceRoom = AttrVal($name, 'deviceRoom', '');
    if ($deviceRoom) {
        my @rooms = split(/\s*,\s*/, $deviceRoom);
        for my $devName (sort keys %main::defs) {
            my $devRoomAttr = AttrVal($devName, 'room', '');
            for my $room (@rooms) {
                if (grep { $_ eq $room } split(/\s*,\s*/, $devRoomAttr)) {
                    unless ($seen{$devName}) {
                        push @devices, $devName;
                        $seen{$devName} = 1;
                    }
                    last;
                }
            }
        }
    }

    my $devList = AttrVal($name, 'deviceList', '');
    $devList = join(',', sort keys %main::defs) if $devList eq '*';
    if ($devList) {
        for my $devName (split(/\s*,\s*/, $devList)) {
            unless ($seen{$devName}) {
                push @devices, $devName;
                $seen{$devName} = 1;
            }
        }
    }

    return '' unless @devices;

    my $contextMode = AttrVal($name, 'deviceContextMode', 'detailed');

    my $context = "Aktueller Status der Smart-Home Geraete:\n";
    my @blacklist = Claude_GetBlacklist($hash);

    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $dev   = $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);
        my $traits = Claude_GetDeviceTraits($devName);

        Log3 $name, 4, "Claude ($name): Alias " . $alias;

        $context .= "\nGeraet: $alias";
        $context .= " (intern: $devName)" if $contextMode ne 'compact';
        $context .= "\n";
        $context .= "  Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n" if $contextMode ne 'compact';
        $context .= "  Status: " . ReadingsVal($devName, 'state', 'unbekannt') . "\n";

        if (exists $dev->{READINGS}) {
            my @selectedReadings = Claude_GetRelevantReadings($devName, max => ($contextMode eq 'compact' ? 3 : 8));
            @selectedReadings = grep { $_ ne 'state' } @selectedReadings;

            my @compactReadings;
            for my $reading (@selectedReadings) {
                next if Claude_IsBlacklisted($reading, @blacklist);
                next unless exists $dev->{READINGS}{$reading};
                my $val = $dev->{READINGS}{$reading}{VAL} // '';
                push @compactReadings, "    $reading: $val";
            }

            if (@compactReadings) {
                $context .= "  Wichtige Readings:\n";
                $context .= join("\n", @compactReadings) . "\n";
            }
        }

        if ($contextMode ne 'compact') {
            my @classes;
            push @classes, 'light'   if $traits->{light};
            push @classes, 'cover'   if $traits->{cover};
            push @classes, 'climate' if $traits->{climate};
            push @classes, 'sensor'  if $traits->{sensor};
            push @classes, 'switch'  if $traits->{switchable} && !$traits->{light};

            $context .= "  Klassen: " . join(', ', @classes) . "\n" if @classes;

            for my $attrName (qw(room group alias comment model subType genericDeviceType)) {
                my $attrVal = AttrVal($devName, $attrName, '');
                $context .= "  $attrName: $attrVal\n" if $attrVal;
            }
        }

        Log3 $name, 4, "Claude ($name): " . $alias . ": " . $context;
    }

    return $context;
}

##############################################################################
# Hilfsfunktion: Geraetekontext fuer control-Befehl aufbauen
##############################################################################
sub Claude_BuildControlContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $controlList = AttrVal($name, 'controlList', '');
    return '' unless $controlList;

    my @devices = split(/\s*,\s*/, $controlList);
    return '' unless @devices;

    my $contextMode = AttrVal($name, 'controlContextMode', 'detailed');
    my @blacklist = Claude_GetBlacklist($hash);

    my $context = "Verfuegbare Geraete zum Steuern:\n";
    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);
        my $state = ReadingsVal($devName, 'state', 'unbekannt');
        my $traits = Claude_GetDeviceTraits($devName);

        my $commandMap = Claude_GetDeviceCommandMap($devName);
        my @cmds = grep { !Claude_IsBlacklisted($_, @blacklist) } sort keys %{$commandMap};

        my @capabilities;
        push @capabilities, 'light'   if $traits->{light};
        push @capabilities, 'cover'   if $traits->{cover};
        push @capabilities, 'climate' if $traits->{climate};
        push @capabilities, 'switch'  if $traits->{switchable} && !$traits->{light};

        my $cmdsStr = @cmds ? join(', ', @cmds[0 .. ($#cmds > 7 ? 7 : $#cmds)]) : 'unbekannt';
        my $capsStr = @capabilities ? join(', ', @capabilities) : 'generic';

        my $comment = AttrVal($devName, 'comment', '');

        if ($contextMode eq 'compact') {
            $context .= "  $alias (intern: $devName, Status: $state, Klassen: $capsStr)";
            $context .= " -- Beschreibung: $comment" if $comment;
            $context .= "\n";
        } else {
            $context .= "  $alias (intern: $devName, Status: $state, Klassen: $capsStr)";
            $context .= " -- Beschreibung: $comment" if $comment;
            $context .= " -- Befehle: $cmdsStr\n";
        }
    }

    return $context;
}

##############################################################################
# Hilfsfunktion: Tool-Definitionen fuer Claude Tool Use zurueckgeben
##############################################################################
sub Claude_GetControlTools {
    return [
        {
            name        => 'set_device',
            description => 'Fuehrt set auf einem FHEM-Geraet aus',
            input_schema => {
                type       => 'object',
                properties => {
                    device  => { type => 'string', description => 'Interner Geraetename' },
                    command => { type => 'string', description => 'set-Befehl oder Wert' }
                },
                required => ['device', 'command']
            }
        },
        {
            name        => 'get_device_state',
            description => 'Liest Status und wichtige Readings eines FHEM-Geraets',
            input_schema => {
                type       => 'object',
                properties => {
                    device => { type => 'string', description => 'Interner Geraetename' }
                },
                required => ['device']
            }
        }
    ];
}

##############################################################################
# Hilfsfunktion: Gueltigen Claude-Chat fuer Tool-Use rekonstruieren
##############################################################################
sub Claude_DebugMessageSummary {
    my ($messages) = @_;
    return '[]' unless $messages && ref($messages) eq 'ARRAY';

    my @summary;
    for my $idx (0 .. $#$messages) {
        my $msg = $messages->[$idx];
        next unless $msg && ref($msg) eq 'HASH';

        my $role = $msg->{role} // '?';
        my $content = $msg->{content};
        my @parts;

        if (ref($content) eq 'ARRAY') {
            for my $part (@$content) {
                next unless ref($part) eq 'HASH';
                my $type = $part->{type} // '?';

                if ($type eq 'text') {
                    push @parts, 'text';
                } elsif ($type eq 'image') {
                    push @parts, 'image';
                } elsif ($type eq 'tool_use') {
                    my $toolName = $part->{name} // '?';
                    my $toolId   = $part->{id}   // '?';
                    push @parts, "tool_use:$toolName:$toolId";
                } elsif ($type eq 'tool_result') {
                    my $toolId = $part->{tool_use_id} // '?';
                    push @parts, "tool_result:$toolId";
                } else {
                    push @parts, $type;
                }
            }
        } else {
            push @parts, 'scalar';
        }

        push @summary, $idx . ':' . $role . '[' . join(',', @parts) . ']';
    }

    return '[' . join(' | ', @summary) . ']';
}

sub Claude_SanitizeMessagesForApi {
    my ($messages, $logName) = @_;
    return [] unless $messages && ref($messages) eq 'ARRAY';

    my @sanitized;
    my @pendingToolIds;

    Log3 $logName, 4, "Claude ($logName): Sanitize input " . Claude_DebugMessageSummary($messages) if defined $logName;

    for my $msg (@$messages) {
        next unless $msg && ref($msg) eq 'HASH';
        my $role = $msg->{role} // '';
        my $content = $msg->{content};

        next unless $role eq 'user' || $role eq 'assistant';
        next unless ref($content) eq 'ARRAY';

        if ($role eq 'assistant') {
            my @toolIds;
            for my $part (@$content) {
                next unless ref($part) eq 'HASH';
                next unless ($part->{type} // '') eq 'tool_use';
                push @toolIds, $part->{id} if defined $part->{id};
            }

            push @sanitized, $msg;
            @pendingToolIds = @toolIds;

            if (@toolIds && defined $logName) {
                Log3 $logName, 4, "Claude ($logName): Sanitize assistant tool_use IDs: " . join(', ', @toolIds);
            }
            next;
        }

        my %expected = map { $_ => 1 } @pendingToolIds;
        if (@pendingToolIds) {
            my @toolResults;
            for my $part (@$content) {
                next unless ref($part) eq 'HASH';
                next unless ($part->{type} // '') eq 'tool_result';
                my $toolUseId = $part->{tool_use_id};
                next unless defined $toolUseId && $expected{$toolUseId};
                push @toolResults, $part;
                delete $expected{$toolUseId};
            }

            if (!%expected && @toolResults == @pendingToolIds) {
                push @sanitized, {
                    role    => 'user',
                    content => \@toolResults
                };
                Log3 $logName, 4, "Claude ($logName): Sanitize matched tool_results for IDs: " . join(', ', @pendingToolIds) if defined $logName;
            } else {
                Log3 $logName, 4, "Claude ($logName): Sanitize dropped incomplete tool turn; expected IDs: " . join(', ', @pendingToolIds) . "; found " . scalar(@toolResults) . " passende tool_results" if defined $logName;
                pop @sanitized;
            }

            @pendingToolIds = ();
            next;
        }

        push @sanitized, $msg;
    }

    if (@pendingToolIds) {
        Log3 $logName, 4, "Claude ($logName): Sanitize removed trailing assistant tool_use without tool_results: " . join(', ', @pendingToolIds) if defined $logName;
        pop @sanitized;
    }

    Log3 $logName, 4, "Claude ($logName): Sanitize output " . Claude_DebugMessageSummary(\@sanitized) if defined $logName;
    return \@sanitized;
}

##############################################################################
# Hilfsfunktion: Control-Session-Chat zuruecksetzen (Fehlerbehandlung)
##############################################################################
sub Claude_RollbackControlSession {
    my ($hash) = @_;
    my $startIdx = $hash->{CONTROL_START_IDX} // 0;
    splice(@{$hash->{CHAT}}, $startIdx);
    delete $hash->{CONTROL_START_IDX};
    delete $hash->{CONTROL_SUCCESSFUL_DEVICES};
    delete $hash->{CONTROL_SUCCESSFUL_COMMANDS};
}

sub Claude_BuildLastControlledContext {
    my ($hash) = @_;
    my $devices = $hash->{LAST_CONTROLLED_DEVICES};

    return '' unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my @parts;
    for my $devName (@$devices) {
        next unless defined $devName && $devName ne '';
        next unless exists $main::defs{$devName};

        my $alias = AttrVal($devName, 'alias', $devName);
        my $state = ReadingsVal($devName, 'state', 'unbekannt');
        push @parts, "$alias (intern: $devName, Status: $state)";
    }

    return '' unless @parts;

    return "Zuletzt erfolgreich gesteuerte Geraete:\n  " . join("\n  ", @parts) . "\n";
}

sub Claude_BuildLastControlBatchContext {
    my ($hash) = @_;
    my $batch = $hash->{LAST_CONTROL_BATCH};

    return '' unless $batch && ref($batch) eq 'HASH';

    my $instruction = $batch->{instruction} // '';
    my $command     = $batch->{command}     // '';
    my $devices     = $batch->{devices};
    my $count       = $batch->{count}       // 0;

    return '' unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my @parts;
    for my $devName (@$devices) {
        next unless defined $devName && $devName ne '';
        next unless exists $main::defs{$devName};

        my $alias = AttrVal($devName, 'alias', $devName);
        my $state = ReadingsVal($devName, 'state', 'unbekannt');
        push @parts, "$alias (intern: $devName, Status: $state)";
    }

    return '' unless @parts;

    my $batchContext = "Letzte Zielmenge fuer Referenzen:\n";
    $batchContext .= "  Anweisung: $instruction\n" if $instruction ne '';
    $batchContext .= "  Befehl: $command\n" if $command ne '';
    $batchContext .= "  Anzahl: $count\n";
    $batchContext .= "  Geraete:\n  " . join("\n  ", @parts) . "\n";

    return $batchContext;
}

sub Claude_BuildControlSystemPrompt {
    my ($hash, %opts) = @_;

    my $includeControlContext = exists $opts{include_control_context} ? $opts{include_control_context} : 1;
    my $name = $hash->{NAME};

    my $systemPrompt            = AttrVal($name, 'systemPrompt', '');
    my $controlContext          = $includeControlContext ? Claude_BuildControlContext($hash) : '';
    my $lastControlledContext   = Claude_BuildLastControlledContext($hash);
    my $lastControlBatchContext = Claude_BuildLastControlBatchContext($hash);

    my @systemParts;
    push @systemParts, $systemPrompt if $systemPrompt ne '';
    push @systemParts, "Steuerregeln:\n- Verweise wie sie/die/diese/wieder/nochmal bevorzugt auf die letzte gemeinsame Zielmenge beziehen.\n- Niemals Tool-Aufrufe mit leerem device oder command erzeugen.\n- Bei Unklarheit bevorzugt die letzte gemeinsame Zielmenge statt nur eines Einzelgeraets nutzen.\n- Wenn weiter unklar, nur eindeutig bestimmbare Geraete verwenden.\n- Nach Erfolg genau 1 kurzen Satz antworten.\n- Keine Geraetelisten ausgeben, ausser bei explizitem Wunsch.\n- Bevorzuge kurze Sammelformulierungen wie 'Die Wohnzimmerbeleuchtung ist jetzt aus.'";
    push @systemParts, $lastControlBatchContext if $lastControlBatchContext ne '';
    push @systemParts, $lastControlledContext if $lastControlledContext ne '';
    push @systemParts, $controlContext if $controlContext ne '';

    return join("\n\n", @systemParts);
}

sub Claude_NormalizeText {
    my ($text) = @_;
    return '' unless defined $text;

    $text = lc($text);
    $text =~ s/ä/ae/g;
    $text =~ s/ö/oe/g;
    $text =~ s/ü/ue/g;
    $text =~ s/ß/ss/g;
    $text =~ s/[^a-z0-9]+/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;

    return $text;
}

sub Claude_GetControlDevices {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $controlList = AttrVal($name, 'controlList', '');
    return () unless $controlList;

    my @devices = grep { defined $_ && $_ ne '' } split(/\s*,\s*/, $controlList);
    return grep { exists $main::defs{$_} } @devices;
}

sub Claude_GetDeviceTraits {
    my ($devName) = @_;
    my %traits;
    return \%traits unless defined $devName && $devName ne '' && exists $main::defs{$devName};

    my $generic = AttrVal($devName, 'genericDeviceType', '');
    my $subType = AttrVal($devName, 'subType', '');
    my $type    = $main::defs{$devName}{TYPE} // '';

    my $commandMap = Claude_GetDeviceCommandMap($devName);
    my %commands   = map { $_ => 1 } keys %{$commandMap};
    my %readings   = map { $_ => 1 } keys %{ $main::defs{$devName}{READINGS} || {} };

    my $genericNorm = Claude_NormalizeText($generic);
    my $subTypeNorm = Claude_NormalizeText($subType);
    my $typeNorm    = Claude_NormalizeText($type);

    $traits{switchable}  = 1 if $commands{on} || $commands{off} || $commands{toggle};
    $traits{dimmable}    = 1 if $commands{bri} || $commands{brightness} || $commands{dim} || $commands{dimUp} || $commands{dimDown};
    $traits{positionable}= 1 if $commands{position};
    $traits{cover}       = 1 if $commands{up} || $commands{down} || $commands{open} || $commands{close} || $commands{stop};
    $traits{climate}     = 1 if $commands{'desired-temp'} || $commands{temperature} || $commands{desiredTemperature} || $commands{temp} || $readings{'desired-temp'} || $readings{'measured-temp'} || $readings{temperature};
    $traits{sensor}      = 1 if !$traits{switchable} && !$traits{dimmable} && !$traits{cover} && !$traits{climate} && %readings;

    my $aliasNorm   = Claude_NormalizeText(AttrVal($devName, 'alias', $devName));
    my $deviceNorm  = Claude_NormalizeText($devName);

    $traits{light}       = 1 if $traits{dimmable};
    $traits{light}       = 1 if !$traits{cover} && !$traits{climate} && ($genericNorm =~ /\blight\b/ || $subTypeNorm =~ /\blight\b/ || $typeNorm =~ /\bhue\b/);
    $traits{light}       = 1 if !$traits{cover} && !$traits{climate} && ($aliasNorm =~ /\b(?:licht|lampe|lampen|led)\b/ || $deviceNorm =~ /\b(?:licht|lampe|lampen|led)\b/);
    $traits{cover}       = 1 if $genericNorm =~ /\bblind\b/ || $genericNorm =~ /\bshutter\b/;
    $traits{climate}     = 1 if $genericNorm =~ /\bthermostat\b/ || $genericNorm =~ /\bclimate\b/;
    $traits{socket}      = 1 if $genericNorm =~ /\bsocket\b/ || $genericNorm =~ /\boutlet\b/ || ($traits{switchable} && !$traits{light} && !$traits{cover} && !$traits{climate});
    $traits{switch}      = 1 if !$traits{light} && !$traits{socket} && $traits{switchable};

    $traits{positionable}= 1 if $traits{cover};
    $traits{positionable}= 1 if !$traits{climate} && !$traits{cover} && $commands{pct};
    $traits{dimmable}    = 1 if !$traits{climate} && !$traits{cover} && $commands{pct};

    return \%traits;
}

sub Claude_GetDeviceCategoryTokens {
    my ($devName) = @_;
    return () unless defined $devName && $devName ne '' && exists $main::defs{$devName};

    my $traits = Claude_GetDeviceTraits($devName);
    my $commandMap = Claude_GetDeviceCommandMap($devName);
    my %commands = map { $_ => 1 } keys %{$commandMap};
    my %tokens;

    my $add_token = sub {
        my ($token) = @_;
        return unless defined $token && $token ne '';
        return if length($token) < 3;
        $tokens{$token} = 1;

        if ($token =~ /e$/) {
            $tokens{$token . 'n'} = 1;
        } elsif ($token !~ /en$/) {
            $tokens{$token . 'e'}  = 1;
            $tokens{$token . 'en'} = 1;
        }

        $tokens{lampen}   = 1 if $token eq 'lampe';
        $tokens{lichter}  = 1 if $token eq 'licht';
        $tokens{rolllaeden} = 1 if $token eq 'rollladen';
    };

    for my $field (
        AttrVal($devName, 'alias', $devName),
        $devName,
        AttrVal($devName, 'group', ''),
        AttrVal($devName, 'room', ''),
        AttrVal($devName, 'genericDeviceType', ''),
        AttrVal($devName, 'subType', ''),
        ($main::defs{$devName}{TYPE} // '')
    ) {
        my $normalized = Claude_NormalizeText($field);
        next unless $normalized ne '';
        for my $token (split(/\s+/, $normalized)) {
            $add_token->($token);
        }
    }

    $add_token->('licht')      if $traits->{light};
    $add_token->('lampe')      if $traits->{light};
    $add_token->('rollladen')  if $traits->{cover};
    $add_token->('heizung')    if $traits->{climate};
    $add_token->('schalter')   if $traits->{socket} || $traits->{switch} || ($traits->{switchable} && !$traits->{light});
    $add_token->('temperatur') if $traits->{climate} || $commands{'desired-temp'} || $commands{temperature};
    $add_token->('position')   if $traits->{cover} || $commands{position};

    return sort keys %tokens;
}

sub Claude_GetIntentSignals {
    my ($instruction) = @_;
    my %signals;
    return \%signals unless defined $instruction;

    my $text = Claude_NormalizeText($instruction);
    return \%signals if $text eq '';

    $signals{turn_on}           = 1 if $text =~ /\b(?:an|anmachen|einschalten|einmachen|ein|on)\b/;
    $signals{turn_off}          = 1 if $text =~ /\b(?:aus|ausschalten|ausmachen|off)\b/;
    $signals{toggle}            = 1 if $text =~ /\b(?:toggle|umschalten)\b/;
    $signals{increase}          = 1 if $text =~ /\b(?:heller|mehr|hoeher|hoher|waermer|warmer|lauter)\b/;
    $signals{decrease}          = 1 if $text =~ /\b(?:dunkler|weniger|niedriger|kuehler|kuhler)\b/;
    $signals{open_like}         = 1 if $text =~ /\b(?:hoch|auf|oeffne|oeffnen|up|open)\b/;
    $signals{close_like}        = 1 if $text =~ /\b(?:runter|zu|schliesse|schliessen|down|close)\b/;
    $signals{stop}              = 1 if $text =~ /\b(?:stop|stopp|anhalten)\b/;
    $signals{percent_value}     = 1 if $text =~ /\b(?:%|prozent|pct)\b/;
    $signals{temperature_value} = 1 if $text =~ /\b(?:grad|temperature|temperatur|desired temp|desiredtemp|solltemperatur)\b/;
    $signals{numeric_value}     = 1 if $text =~ /\b-?\d+(?:[.,]\d+)?\b/;

    return \%signals;
}

sub Claude_CommandFamilyDefinitions {
    return {
        switch_on         => [qw(on on-for-timer on-till on-till-overnight)],
        switch_off        => [qw(off off-for-timer off-till off-till-overnight)],
        toggle            => [qw(toggle)],
        increase_light    => [qw(dimUp brighter bri brightness pct)],
        decrease_light    => [qw(dimDown darker bri brightness pct)],
        increase_cover    => [qw(up open position pct)],
        decrease_cover    => [qw(down close position pct)],
        increase_climate  => [qw(desired-temp temperature desiredTemperature temp targetTemperature)],
        decrease_climate  => [qw(desired-temp temperature desiredTemperature temp targetTemperature)],
        stop              => [qw(stop)],
        value_position    => [qw(position pct level)],
        value_brightness  => [qw(bri brightness dim pct)],
        value_temperature => [qw(desired-temp temperature desiredTemperature temp targetTemperature)],
        open_like         => [qw(open up position pct on)],
        close_like        => [qw(close down position pct off)],
    };
}

sub Claude_GetCommandFamiliesForInstruction {
    my ($instruction, $devices) = @_;
    return () unless defined $instruction;
    return () unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my $signals = Claude_GetIntentSignals($instruction);
    my %traits;
    my @families;

    for my $device (@$devices) {
        my $deviceTraits = Claude_GetDeviceTraits($device);
        for my $trait (keys %{$deviceTraits}) {
            $traits{$trait}++ if $deviceTraits->{$trait};
        }
    }

    push @families, 'switch_off'        if $signals->{turn_off};
    push @families, 'switch_on'         if $signals->{turn_on};
    push @families, 'toggle'            if $signals->{toggle};
    push @families, 'stop'              if $signals->{stop};
    push @families, 'value_temperature' if $signals->{temperature_value};
    push @families, 'open_like'         if $signals->{open_like};
    push @families, 'close_like'        if $signals->{close_like};

    if ($signals->{percent_value}) {
        push @families, 'value_position'    if $traits{cover} || $traits{positionable};
        push @families, 'value_brightness'  if !$traits{cover} && ($traits{dimmable} || $traits{light});
    }

    if ($signals->{increase}) {
        push @families, 'increase_climate' if $traits{climate};
        push @families, 'increase_cover'   if $traits{cover};
        push @families, 'increase_light'   if $traits{dimmable} || $traits{light};
    }

    if ($signals->{decrease}) {
        push @families, 'decrease_climate' if $traits{climate};
        push @families, 'decrease_cover'   if $traits{cover};
        push @families, 'decrease_light'   if $traits{dimmable} || $traits{light};
    }

    if ($signals->{numeric_value} && !grep { $_ eq 'value_brightness' || $_ eq 'value_position' || $_ eq 'value_temperature' } @families) {
        push @families, 'value_temperature' if $traits{climate};
        push @families, 'value_position'    if !$traits{climate} && ($traits{cover} || $traits{positionable});
        push @families, 'value_brightness'  if !$traits{climate} && !$traits{cover} && ($traits{dimmable} || $traits{light});
    }

    my %seen;
    return grep { !$seen{$_}++ } @families;
}

sub Claude_MatchDeviceType {
    my ($instruction, $devices) = @_;
    my $text = Claude_NormalizeText($instruction);
    return '' if $text eq '';
    return '' unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my %counts;
    my %categoryTokensByDevice;

    for my $device (@$devices) {
        my @tokens = Claude_GetDeviceCategoryTokens($device);
        $categoryTokensByDevice{$device} = \@tokens;

        for my $token (@tokens) {
            next unless $token ne '';
            $counts{$token}++ if $text =~ /\b\Q$token\E\b/;
        }
    }

    return '' unless %counts;
    my $best = (sort { $counts{$b} <=> $counts{$a} || length($b) <=> length($a) || $a cmp $b } keys %counts)[0];
    my @candidateTypes = ($best);

    if ($best eq 'lampe' || $best eq 'lampen') {
        push @candidateTypes, 'lampe', 'lampen';
    } elsif ($best eq 'lichter' || $best eq 'licht') {
        push @candidateTypes, 'licht', 'lichter', 'led';
    }

    my $room = Claude_MatchRoomToken($instruction, $devices);
    if ($room ne '') {
        my @roomFiltered = grep {
            my $roomAttr = AttrVal($_, 'room', '');
            my @rooms = split(/\s*,\s*/, $roomAttr);
            my %roomTokens;

            for my $roomEntry (@rooms) {
                my $normRoom = Claude_NormalizeText($roomEntry);
                next unless $normRoom ne '';
                for my $token (grep { $_ ne '' && length($_) >= 3 } split(/\s+/, $normRoom)) {
                    $roomTokens{$token} = 1;
                }
            }

            exists $roomTokens{$room};
        } @$devices;

        if (@roomFiltered) {
            my %typeMatches;
            for my $device (@roomFiltered) {
                my %tokenSet = map { $_ => 1 } @{ $categoryTokensByDevice{$device} || [] };
                for my $candidate (@candidateTypes) {
                    $typeMatches{$candidate}++ if $tokenSet{$candidate};
                }
            }

            for my $candidate (@candidateTypes) {
                return $candidate if $typeMatches{$candidate};
            }
        }
    }

    return 'lampe' if $best eq 'lampe' || $best eq 'lampen';
    return 'licht' if $best eq 'lichter';
    return $best;
}

sub Claude_GetCandidateCommandsForInstruction {
    my ($instruction, $devices) = @_;
    return () unless defined $instruction;
    return () unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my %available;
    for my $device (@$devices) {
        my $commandMap = Claude_GetDeviceCommandMap($device);
        for my $cmd (keys %{$commandMap}) {
            $available{$cmd}++;
        }
    }

    my $families = Claude_CommandFamilyDefinitions();
    my @requestedFamilies = Claude_GetCommandFamiliesForInstruction($instruction, $devices);
    my @candidates;

    for my $family (@requestedFamilies) {
        next unless exists $families->{$family};
        push @candidates, @{ $families->{$family} };
    }

    my %seen;
    @candidates = grep { $_ ne '' && !$seen{$_}++ && $available{$_} } @candidates;

    return @candidates;
}

sub Claude_ResolveCommandFromCandidates {
    my ($devices, $candidates) = @_;
    return '' unless $devices && ref($devices) eq 'ARRAY' && @$devices;
    return '' unless $candidates && ref($candidates) eq 'ARRAY' && @$candidates;

    for my $candidate (@$candidates) {
        return $candidate if Claude_AllDevicesSupportCommand($devices, $candidate);
    }

    return '';
}

sub Claude_ResolveValueCommandFromCandidates {
    my ($devices, $candidates, $value) = @_;
    return '' unless defined $value && $value ne '';
    return '' unless $devices && ref($devices) eq 'ARRAY' && @$devices;
    return '' unless $candidates && ref($candidates) eq 'ARRAY' && @$candidates;

    COMMAND:
    for my $candidate (@$candidates) {
        for my $device (@$devices) {
            next COMMAND unless Claude_DeviceSupportsValueForCommand($device, $candidate, $value);
        }
        return $candidate;
    }

    return '';
}

sub Claude_MatchRoomToken {
    my ($instruction, $devices) = @_;
    my $text = Claude_NormalizeText($instruction);
    return '' if $text eq '';
    return '' unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my %roomCounts;
    for my $devName (@$devices) {
        my $roomAttr = AttrVal($devName, 'room', '');
        next unless $roomAttr ne '';

        for my $room (split(/\s*,\s*/, $roomAttr)) {
            my $normRoom = Claude_NormalizeText($room);
            next unless $normRoom ne '';

            my @tokens = grep { $_ ne '' && length($_) >= 3 } split(/\s+/, $normRoom);
            next unless @tokens;

            for my $token (@tokens) {
                $roomCounts{$token}++;
            }
        }
    }

    for my $room (sort { $roomCounts{$b} <=> $roomCounts{$a} || length($b) <=> length($a) || $a cmp $b } keys %roomCounts) {
        return $room if $text =~ /\b\Q$room\E\b/;
    }

    return '';
}

sub Claude_IsSpeakableRoomLabel {
    my ($room) = @_;
    return 0 unless defined $room && $room ne '';

    return 0 if $room =~ /(?:->|\/|:|;|\|)/;
    return 0 if $room =~ /(?:^|\s)(?:und|oder)(?:\s|$)/i;

    my $norm = Claude_NormalizeText($room);
    return 0 if $norm eq '';
    return 0 if $norm =~ /\b(?:ablauf|ablaeufe|beleuchtung|licht|lampen|lampe|gruppe|group|szene|scene)\b/;

    my @tokens = grep { $_ ne '' } split(/\s+/, $norm);
    return 0 unless @tokens;
    return 0 if @tokens > 4;

    return 1;
}

sub Claude_InferDominantRoomFromDevices {
    my ($devices) = @_;
    return '' unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my %roomCount;
    my %roomLabel;

    for my $devName (@$devices) {
        next unless defined $devName && $devName ne '' && exists $main::defs{$devName};

        my $roomAttr = AttrVal($devName, 'room', '');
        next unless $roomAttr ne '';

        my @rooms = grep { $_ ne '' } split(/\s*,\s*/, $roomAttr);
        my @candidateRooms = grep { Claude_IsSpeakableRoomLabel($_) } @rooms;
        next unless @candidateRooms;

        my $label = $candidateRooms[0];
        my $norm  = Claude_NormalizeText($label);
        next unless $norm ne '';

        $roomCount{$norm}++;
        $roomLabel{$norm} = $label unless exists $roomLabel{$norm};
    }

    return '' unless %roomCount;

    my ($bestNorm) = sort { $roomCount{$b} <=> $roomCount{$a} || $a cmp $b } keys %roomCount;
    return '' unless defined $bestNorm && $bestNorm ne '';
    return '' unless $roomCount{$bestNorm} == scalar(@$devices);

    return $roomLabel{$bestNorm} // '';
}

sub Claude_TitleCaseRoomLabel {
    my ($room) = @_;
    return '' unless defined $room && $room ne '';

    my @parts = split(/\s+/, $room);
    @parts = map {
        my $part = $_;
        $part =~ s/^([[:alpha:]])/\U$1/;
        $part;
    } @parts;

    return join(' ', @parts);
}

sub Claude_GetRememberedBatchRoomLabel {
    my ($hash, $devices, $batchOverride) = @_;
    return '' unless $hash && ref($hash) eq 'HASH';

    my $batch = ($batchOverride && ref($batchOverride) eq 'HASH') ? $batchOverride : $hash->{LAST_CONTROL_BATCH};
    if ($batch && ref($batch) eq 'HASH') {
        my $instruction  = $batch->{instruction} // '';
        my $batchDevices = $batch->{devices};

        if ($instruction ne '' && $batchDevices && ref($batchDevices) eq 'ARRAY' && @$batchDevices) {
            my $instructionRoom = Claude_MatchRoomToken($instruction, $batchDevices);
            return Claude_TitleCaseRoomLabel($instructionRoom) if $instructionRoom ne '';

            my $deviceRoom = Claude_InferDominantRoomFromDevices($batchDevices);
            return Claude_TitleCaseRoomLabel($deviceRoom) if $deviceRoom ne '';
        }
    }

    if ($devices && ref($devices) eq 'ARRAY' && @$devices) {
        my $deviceRoom = Claude_InferDominantRoomFromDevices($devices);
        return Claude_TitleCaseRoomLabel($deviceRoom) if $deviceRoom ne '';
    }

    return '';
}

sub Claude_ShouldPreferRememberedBatchRoom {
    my ($hash, $instruction, $devices, $batchOverride) = @_;
    return 0 unless $hash && ref($hash) eq 'HASH';
    return 0 unless $devices && ref($devices) eq 'ARRAY' && @$devices;
    return 0 unless Claude_IsReferentialFollowupInstruction($instruction, $hash);

    my $currentRoom = Claude_InferDominantRoomFromDevices($devices);
    return 1 if $currentRoom eq '';

    my $rememberedRoom = Claude_GetRememberedBatchRoomLabel($hash, $devices, $batchOverride);
    return 0 if $rememberedRoom eq '';

    my $currentNorm    = Claude_NormalizeText($currentRoom);
    my $rememberedNorm = Claude_NormalizeText($rememberedRoom);

    return ($currentNorm ne '' && $rememberedNorm ne '' && $currentNorm eq $rememberedNorm) ? 1 : 0;
}

sub Claude_GetDeviceCommandMap {
    my ($devName) = @_;
    my %commands;
    return \%commands unless defined $devName && $devName ne '' && exists $main::defs{$devName};

    my $setListRaw = main::getAllSets($devName) // '';
    $setListRaw =~ s/\r\n/\n/g;
    $setListRaw =~ s/[\r\t]+/ /g;
    $setListRaw =~ s/^\s+|\s+$//g;

    return \%commands if $setListRaw eq '';

    my @entries;
    my $buffer = '';
    my $in_single = 0;
    my $in_double = 0;
    my $brace_depth = 0;
    my $paren_depth = 0;
    my $bracket_depth = 0;
    my $escaped = 0;

    for my $char (split(//, $setListRaw)) {
        if ($escaped) {
            $buffer .= $char;
            $escaped = 0;
            next;
        }

        if ($char eq '\\') {
            $buffer .= $char;
            $escaped = 1;
            next;
        }

        if (!$in_double && $char eq "'") {
            $in_single = !$in_single;
            $buffer .= $char;
            next;
        }

        if (!$in_single && $char eq '"') {
            $in_double = !$in_double;
            $buffer .= $char;
            next;
        }

        if (!$in_single && !$in_double) {
            $brace_depth++   if $char eq '{';
            $brace_depth--   if $char eq '}' && $brace_depth > 0;
            $paren_depth++   if $char eq '(';
            $paren_depth--   if $char eq ')' && $paren_depth > 0;
            $bracket_depth++ if $char eq '[';
            $bracket_depth-- if $char eq ']' && $bracket_depth > 0;

            if ($char =~ /\s/ && $brace_depth == 0 && $paren_depth == 0 && $bracket_depth == 0) {
                if ($buffer ne '') {
                    push @entries, $buffer;
                    $buffer = '';
                }
                next;
            }
        }

        $buffer .= $char;
    }

    push @entries, $buffer if $buffer ne '';

    for my $entry (@entries) {
        next unless defined $entry;
        $entry =~ s/^\s+|\s+$//g;
        next if $entry eq '';

        my ($cmdName, $spec) = split(/:/, $entry, 2);
        next unless defined $cmdName && $cmdName ne '';
        next if $cmdName =~ /^\?/;
        next if $cmdName =~ /\s/;

        $spec = '' unless defined $spec;
        $spec =~ s/^\s+|\s+$//g;

        $commands{$cmdName} = $spec;
    }

    return \%commands;
}

sub Claude_DeviceSupportsCommand {
    my ($devName, $command) = @_;
    return 0 unless defined $devName && defined $command && $command ne '';

    my $commandMap = Claude_GetDeviceCommandMap($devName);
    return exists $commandMap->{$command} ? 1 : 0;
}

sub Claude_AllDevicesSupportCommand {
    my ($devices, $command) = @_;
    return 0 unless $devices && ref($devices) eq 'ARRAY' && @$devices;
    return 0 unless defined $command && $command ne '';

    for my $devName (@$devices) {
        return 0 unless Claude_DeviceSupportsCommand($devName, $command);
    }

    return 1;
}

sub Claude_NormalizeSetSpecValue {
    my ($value) = @_;
    return '' unless defined $value;

    my $normalized = lc($value);
    $normalized =~ s/^\s+|\s+$//g;
    $normalized =~ s/ä/ae/g;
    $normalized =~ s/ö/oe/g;
    $normalized =~ s/ü/ue/g;
    $normalized =~ s/ß/ss/g;
    $normalized =~ s/\s+/ /g;

    return $normalized;
}

sub Claude_DeviceSupportsValueForCommand {
    my ($devName, $command, $value) = @_;
    return 0 unless defined $devName && defined $command && defined $value;
    return 0 unless exists $main::defs{$devName};

    my $commandMap = Claude_GetDeviceCommandMap($devName);
    return 0 unless exists $commandMap->{$command};

    my $spec = $commandMap->{$command} // '';
    return 1 if $spec eq '';

    my $normalizedValue = Claude_NormalizeSetSpecValue($value);
    my $numericValue = $normalizedValue;
    $numericValue =~ s/,/./g;

    if ($spec =~ /^slider,(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$/) {
        my ($min, undef, $max) = ($1, $2, $3);
        return 0 unless $numericValue =~ /^-?\d+(?:\.\d+)?$/;
        return ($numericValue >= $min && $numericValue <= $max) ? 1 : 0;
    }

    if ($spec =~ /^([^,]+(?:,[^,]+)*)$/) {
        my %allowed = map { Claude_NormalizeSetSpecValue($_) => 1 } split(/,/, $spec);
        return exists $allowed{$normalizedValue} ? 1 : 0;
    }

    return 1;
}

sub Claude_IsLocalInstructionStructurallySafe {
    my ($instruction) = @_;
    return 0 unless defined $instruction;

    my $rawText = lc($instruction);
    $rawText =~ s/[.!]+/ /g;
    $rawText =~ s/\b(?:bitte|mal)\b//g;
    $rawText =~ s/\s+/ /g;
    $rawText =~ s/^\s+|\s+$//g;

    return 0 if $rawText =~ /[,;:]/;
    return 0 if $rawText =~ /\b(?:aber|jedoch|sondern|statt|ausser|sowie|waehrend|wahrend|bis auf|mit ausnahme|erst|zuerst|anschliessend|anschliesend|nur|lediglich|ausschliesslich|nicht|kein|keine|keinen|keinem|keiner|wenn|falls|spaeter)\b/;

    my $text = Claude_NormalizeText($instruction);
    $text =~ s/\b(?:bitte|mal)\b/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    return 0 if $text eq '';

    return 0 if $text =~ /\b(?:haelfte|halb|teil|ein paar|paar|mehrere|wenige|einige)\b/;

    my @actionPositions;
    while ($text =~ /\b(?:schalte|schalt|mache|mach|lass|lasse|schalten|einschalten|ausschalten|anmachen|ausmachen|umschalten|dimme|dimmen|oeffne|oeffnen|schliesse|schliessen|fahre|stoppe|stelle|setz|setze)\b/g) {
        push @actionPositions, pos($text);
        return 0 if @actionPositions > 1;
    }

    return 1;
}

sub Claude_InferIntentClass {
    my ($instruction, $hash) = @_;
    return 'unsupported' unless defined $instruction;

    my $text = Claude_NormalizeText($instruction);
    return 'unsupported' if $text eq '';
    return 'unsupported' unless Claude_IsLocalInstructionStructurallySafe($instruction);

    my $signals = Claude_GetIntentSignals($instruction);

    my @controlDevices = $hash ? Claude_GetControlDevices($hash) : ();
    my @aliasMatches   = @controlDevices ? Claude_MatchDevicesByAlias($instruction, \@controlDevices) : ();
    my $room           = @controlDevices ? Claude_MatchRoomToken($instruction, \@controlDevices) : '';
    my $type           = @controlDevices ? Claude_MatchDeviceType($instruction, \@controlDevices) : '';

    my $hasConcreteTarget = (@aliasMatches || $room ne '' || $type ne '') ? 1 : 0;

    if (Claude_IsReferentialFollowupInstruction($instruction, $hash)) {
        if (!$hasConcreteTarget) {
            return 'referential_followup';
        }

        if ($hash && ref($hash) eq 'HASH') {
            my $name = $hash->{NAME} // '-';
            Log3 $name, 4, "Claude ($name): LocalResolver referential-followup verworfen wegen konkretem Ziel aliasMatches=[" . join(', ', @aliasMatches) . "] room='$room' type='$type'";
        }
    }

    return 'value_assignment' if $signals->{numeric_value};
    return 'device_command' if $signals->{turn_on} || $signals->{turn_off} || $signals->{toggle} || $signals->{increase} || $signals->{decrease} || $signals->{open_like} || $signals->{close_like} || $signals->{stop};

    return 'unsupported';
}

sub Claude_InferValueCommand {
    my ($instruction, $devices) = @_;
    return ('', '') unless defined $instruction;

    my $text = Claude_NormalizeText($instruction);
    return ('', '') if $text eq '';

    my ($valueToken) = ($text =~ /\b(-?\d+(?:[.,]\d+)?)\b/);
    return ('', '') unless defined $valueToken && $valueToken ne '';

    $valueToken =~ s/,/./g;

    my @candidates = Claude_GetCandidateCommandsForInstruction($instruction, $devices);
    my $command = Claude_ResolveValueCommandFromCandidates($devices, \@candidates, $valueToken);

    return ($command, $valueToken) if $command ne '';
    return ('', '');
}

sub Claude_InferDeviceCommand {
    my ($instruction, $devices) = @_;
    return ('', '') unless defined $instruction;

    my @candidates = Claude_GetCandidateCommandsForInstruction($instruction, $devices);
    my $command = Claude_ResolveCommandFromCandidates($devices, \@candidates);

    return ($command, '') if $command ne '';
    return ('', '');
}

sub Claude_MatchDevicesByAlias {
    my ($instruction, $devices) = @_;
    return () unless defined $instruction;
    return () unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my $text = Claude_NormalizeText($instruction);
    return () if $text eq '';

    my %genericTokens = map { $_ => 1 } qw(
        licht lichter lampe lampen led beleuchtung wohnzimmer badezimmer schlafzimmer kueche kuche
        flur wintergarten bad spiegel decke deckenlicht deckenleuchte deckenlampen
        schalter steckdose steckdosen heizung heizungen thermostat thermostate klima
        rollladen rolllaeden jalousie jalousien raffstore raffstores
    );

    my @matched;
    for my $devName (@$devices) {
        my %seen;
        my @tokens;

        for my $field (
            AttrVal($devName, 'alias', ''),
            $devName
        ) {
            my $normalized = Claude_NormalizeText($field);
            next unless $normalized ne '';
            for my $token (grep { $_ ne '' && length($_) >= 3 } split(/\s+/, $normalized)) {
                next if $genericTokens{$token};
                next if $token =~ /^\d+(?:\d+)?$/;
                push @tokens, $token;
            }
        }

        @tokens = grep { !$seen{$_}++ } @tokens;
        next unless @tokens;

        if (grep { $text =~ /\b\Q$_\E\b/ } @tokens) {
            push @matched, $devName;
        }
    }

    return @matched;
}

sub Claude_InferLocalCommand {
    my ($instruction, $devices) = @_;
    return Claude_InferDeviceCommand($instruction, $devices);
}

sub Claude_NormalizeDeviceTypeToken {
    my ($token) = @_;
    return '' unless defined $token && $token ne '';

    $token = Claude_NormalizeText($token);
    return '' if $token eq '';

    return 'lampe'   if $token =~ /^(?:lampe|lampen)$/;
    return 'licht'   if $token =~ /^(?:light|licht|lichter|led)$/;
    return 'cover'   if $token =~ /^(?:cover|rollladen|rolllaeden|jalousie|jalousien|raffstore|raffstores)$/;
    return 'climate' if $token =~ /^(?:climate|heizung|heizungen|thermostat|thermostate|klima)$/;
    return 'switch'  if $token =~ /^(?:switch|schalter|schaltere|schalteren|steckdose|steckdosen)$/;

    return $token;
}

sub Claude_DeviceMatchesNormalizedType {
    my ($devName, $type) = @_;
    return 0 unless defined $devName && $devName ne '';
    return 0 unless defined $type && $type ne '';
    return 0 unless exists $main::defs{$devName};

    my $normalizedType = Claude_NormalizeDeviceTypeToken($type);
    return 0 if $normalizedType eq '';

    my $aliasNorm  = Claude_NormalizeText(AttrVal($devName, 'alias', $devName));
    my $deviceNorm = Claude_NormalizeText($devName);
    my $traits     = Claude_GetDeviceTraits($devName);

    if ($normalizedType eq 'lampe') {
        return 1 if $aliasNorm =~ /\b(?:lampe|lampen)\b/;
        return 1 if $deviceNorm =~ /\b(?:lampe|lampen)\b/;
        return 0;
    }

    if ($normalizedType eq 'licht') {
        return 1 if $aliasNorm =~ /\b(?:licht|lichter|led)\b/;
        return 1 if $deviceNorm =~ /\b(?:licht|lichter|led)\b/;
        return 1 if !$traits->{cover} && !$traits->{climate} && $traits->{light} && !$traits->{switch} && $aliasNorm !~ /\b(?:lampe|lampen)\b/ && $deviceNorm !~ /\b(?:lampe|lampen)\b/;
        return 0;
    }

    if ($normalizedType eq 'switch') {
        return 1 if $traits->{switch} || $traits->{socket} || ($traits->{switchable} && !$traits->{light});
        return 0;
    }

    if ($normalizedType eq 'cover') {
        return $traits->{cover} ? 1 : 0;
    }

    if ($normalizedType eq 'climate') {
        return $traits->{climate} ? 1 : 0;
    }

    my @tokens = Claude_GetDeviceCategoryTokens($devName);
    my %tokenSet = map { Claude_NormalizeDeviceTypeToken($_) => 1 } @tokens;
    return exists $tokenSet{$normalizedType} ? 1 : 0;
}

sub Claude_InferGroupLabelFromDevices {
    my ($devices) = @_;
    return 'Die Geraete' unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my %traits;
    for my $device (@$devices) {
        my $deviceTraits = Claude_GetDeviceTraits($device);
        for my $key (keys %{$deviceTraits}) {
            $traits{$key}++ if $deviceTraits->{$key};
        }
    }

    my $count = scalar(@$devices);
    my $coverCount    = $traits{cover}   // 0;
    my $climateCount  = $traits{climate} // 0;
    my $lightCount    = $traits{light}   // 0;
    my $socketCount   = $traits{socket}  // 0;
    my $switchCount   = $traits{switch}  // 0;

    return 'Die Geraete'                 if $count <= 0;
    return 'Die Rollaeden'               if $coverCount   == $count;
    return 'Die Heizungen'               if $climateCount == $count;
    return 'Die Beleuchtung'             if $lightCount   == $count;
    return 'Die Schalter'                if $switchCount == $count;
    return 'Die Steckdosen'              if $socketCount == $count;
    return 'Die Schalter und Steckdosen' if ($socketCount + $switchCount) >= $count;
    return 'Die Geraete';
}

sub Claude_LocalSummaryVariantIndex {
    my ($hash, $bucket, @seedParts) = @_;

    my $counter = 0;
    if ($hash && ref($hash) eq 'HASH') {
        $hash->{LOCAL_SUMMARY_VARIANT_COUNTER} ||= 0;
        $hash->{LOCAL_SUMMARY_VARIANT_COUNTER}++;
        $counter = $hash->{LOCAL_SUMMARY_VARIANT_COUNTER};
    }

    my $seed = join('|', ($bucket // ''), @seedParts, $counter);
    my $sum = 0;
    $sum += ord($_) for split(//, $seed);

    return $sum;
}

sub Claude_LocalSummaryChooseWeighted {
    my ($hash, $bucket, $weightedValues, @seedParts) = @_;
    return '' unless $weightedValues && ref($weightedValues) eq 'ARRAY' && @$weightedValues;

    my $total = 0;
    for my $entry (@$weightedValues) {
        next unless ref($entry) eq 'ARRAY';
        my $weight = $entry->[1] // 0;
        $total += $weight if $weight > 0;
    }
    return $weightedValues->[0][0] if $total <= 0;

    my $index = Claude_LocalSummaryVariantIndex($hash, $bucket, @seedParts) % $total;
    my $running = 0;

    for my $entry (@$weightedValues) {
        next unless ref($entry) eq 'ARRAY';
        my ($value, $weight) = @$entry;
        $weight ||= 0;
        next if $weight <= 0;
        $running += $weight;
        return $value if $index < $running;
    }

    return $weightedValues->[0][0];
}

sub Claude_LocalSummaryTemporalAdverb {
    my ($hash, $instruction, $command, $devices, $subject, $hasRepeatCue) = @_;

    return Claude_LocalSummaryChooseWeighted(
        $hash,
        'temporal',
        [
            [' jetzt', 6],
            [' nun',   1],
            ['',       3],
        ],
        Claude_NormalizeText($instruction // ''),
        ($command // ''),
        ($subject // ''),
        ($hasRepeatCue ? 'repeat' : 'plain'),
        ($devices && ref($devices) eq 'ARRAY' ? scalar(@$devices) : 0)
    );
}

sub Claude_LocalSummaryRepeatPhrase {
    my ($hash, $instruction, $command, $subject) = @_;

    return Claude_LocalSummaryChooseWeighted(
        $hash,
        'repeat',
        [
            [' wieder', 6],
            [' erneut', 1],
            ['',        1],
        ],
        Claude_NormalizeText($instruction // ''),
        ($command // ''),
        ($subject // '')
    );
}

sub Claude_LocalSummarySetVerb {
    my ($hash, $instruction, $command, $subject) = @_;

    return Claude_LocalSummaryChooseWeighted(
        $hash,
        'setverb',
        [
            ['gesetzt',     5],
            ['eingestellt', 2],
        ],
        Claude_NormalizeText($instruction // ''),
        ($command // ''),
        ($subject // '')
    );
}

sub Claude_LocalSummaryDoneVerb {
    my ($hash, $instruction, $command, $subject, $isSingle) = @_;

    return Claude_LocalSummaryChooseWeighted(
        $hash,
        'doneverb',
        [
            ['ausgefuehrt', 5],
            ['erledigt',    1],
        ],
        Claude_NormalizeText($instruction // ''),
        ($command // ''),
        ($subject // ''),
        ($isSingle ? 'single' : 'multi')
    );
}

sub Claude_LocalSummaryMotionPhrase {
    my ($hash, $instruction, $command, $subject, $takesSingular) = @_;

    my $bucket = $takesSingular ? 'motion-single' : 'motion-multi';
    my $variants = $takesSingular
        ? [
            ['bewegt sich',  5],
            ['faehrt',       2],
            ['geht',         1],
          ]
        : [
            ['bewegen sich', 5],
            ['fahren',       2],
            ['gehen',        1],
          ];

    return Claude_LocalSummaryChooseWeighted(
        $hash,
        $bucket,
        $variants,
        Claude_NormalizeText($instruction // ''),
        ($command // ''),
        ($subject // '')
    );
}

sub Claude_LocalSummaryMotionDirectionPhrase {
    my ($hash, $instruction, $command, $subject, $takesSingular) = @_;

    my $direction = $command eq 'up' ? 'up' : 'down';
    my $bucket = 'motion-direction-' . $direction . '-' . ($takesSingular ? 'single' : 'multi');

    my $variants = $command eq 'up'
        ? [
            ['nach oben', 5],
            ['hoch',      2],
          ]
        : [
            ['nach unten', 5],
            ['runter',     2],
          ];

    return Claude_LocalSummaryChooseWeighted(
        $hash,
        $bucket,
        $variants,
        Claude_NormalizeText($instruction // ''),
        ($command // ''),
        ($subject // '')
    );
}

sub Claude_LocalSummaryValueUnit {
    my ($command) = @_;
    return '%'    if defined $command && $command =~ /^(?:pct|bri|brightness|position)\b/;
    return 'Grad' if defined $command && $command =~ /^(?:desired-temp|temperature|desiredTemperature|temp)\b/;
    return '';
}

sub Claude_LocalSummaryValuePhrase {
    my ($hash, $instruction, $command, $subject, $value, $unit, $takesSingular) = @_;

    my $normalized = defined $value ? $value : '';
    $normalized =~ s/^\s+|\s+$//g;
    my $bucket = 'valuephrase-' . ($takesSingular ? 'single' : 'multi');

    my @variants = (
        ["auf $normalized" . ($unit ne '' ? " $unit" : ''), 5],
        ["bei $normalized" . ($unit ne '' ? " $unit" : ''), 2],
    );

    return Claude_LocalSummaryChooseWeighted(
        $hash,
        $bucket,
        \@variants,
        Claude_NormalizeText($instruction // ''),
        ($command // ''),
        ($subject // ''),
        ($normalized // ''),
        ($unit // '')
    );
}

sub Claude_BuildLocalControlSummary {
    my ($instruction, $command, $devices, $hash, %opts) = @_;
    my $count = $devices && ref($devices) eq 'ARRAY' ? scalar(@$devices) : 0;
    my $instructionRoom = Claude_MatchRoomToken($instruction, $devices);
    my $deviceRoom      = Claude_InferDominantRoomFromDevices($devices);
    my $roomLabel       = $instructionRoom ne '' ? Claude_TitleCaseRoomLabel($instructionRoom) : Claude_TitleCaseRoomLabel($deviceRoom);
    my $referenceBatch  = ($opts{reference_batch} && ref($opts{reference_batch}) eq 'HASH') ? $opts{reference_batch} : undef;

    my $isReferentialFollowup = Claude_IsReferentialFollowupInstruction($instruction, $hash) ? 1 : 0;
    my $hasRepeatCue          = Claude_HasRepeatCue($instruction) ? 1 : 0;

    if ($isReferentialFollowup && Claude_ShouldPreferRememberedBatchRoom($hash, $instruction, $devices, $referenceBatch)) {
        my $rememberedRoom = Claude_GetRememberedBatchRoomLabel($hash, $devices, $referenceBatch);
        $roomLabel = $rememberedRoom if $rememberedRoom ne '';
    }

    my $subject = Claude_InferGroupLabelFromDevices($devices);

    my $infer_subject_from_devices = sub {
        my ($targetDevices, $resolvedRoomLabel) = @_;
        return 'Die Geraete' unless $targetDevices && ref($targetDevices) eq 'ARRAY' && @$targetDevices;

        my $allLampen = 1;
        my $allLicht  = 1;

        for my $dev (@$targetDevices) {
            $allLampen = 0 unless Claude_DeviceMatchesNormalizedType($dev, 'lampe');
            $allLicht  = 0 unless Claude_DeviceMatchesNormalizedType($dev, 'licht');
        }

        return 'Die Lampen' if $allLampen;
        return 'Das Licht' if $allLicht;

        if (Claude_InferGroupLabelFromDevices($targetDevices) eq 'Die Beleuchtung') {
            return 'Die Beleuchtung';
        }

        my $genericLabel = Claude_InferGroupLabelFromDevices($targetDevices);
        return $genericLabel if $genericLabel ne 'Die Geraete';

        my %typeBuckets = (
            lampen => [],
            licht  => [],
            covers => [],
            klima  => [],
            sonst  => [],
        );

        for my $dev (@$targetDevices) {
            if (Claude_DeviceMatchesNormalizedType($dev, 'lampe')) {
                push @{$typeBuckets{lampen}}, $dev;
            } elsif (Claude_DeviceMatchesNormalizedType($dev, 'licht')) {
                push @{$typeBuckets{licht}}, $dev;
            } else {
                my $traits = Claude_GetDeviceTraits($dev);
                if ($traits->{cover}) {
                    push @{$typeBuckets{covers}}, $dev;
                } elsif ($traits->{climate}) {
                    push @{$typeBuckets{klima}}, $dev;
                } else {
                    push @{$typeBuckets{sonst}}, $dev;
                }
            }
        }

        my @parts;
        push @parts, 'Lampen'    if @{$typeBuckets{lampen}};
        push @parts, 'Licht'     if @{$typeBuckets{licht}};
        push @parts, 'Rollaeden' if @{$typeBuckets{covers}};
        push @parts, 'Heizungen' if @{$typeBuckets{klima}};
        push @parts, 'Geraete'   if @{$typeBuckets{sonst}};

        if (@parts == 1) {
            my $label = "Die $parts[0]";
            $label = "Das Licht" if $parts[0] eq 'Licht';
            return $label;
        }

        if (@parts >= 2) {
            my $last = pop @parts;
            my $joined = join(', ', @parts) . ' und ' . $last;
            return "Die $joined";
        }

        return 'Die Geraete';
    };

    if ($count == 1 && $devices && @$devices) {
        my $alias = AttrVal($devices->[0], 'alias', $devices->[0]);
        $subject = $alias;
    } else {
        $subject = $infer_subject_from_devices->($devices, $roomLabel);
    }

    my $is_single = ($count == 1) ? 1 : 0;

    my $takes_singular = ($is_single || $subject =~ /\bBeleuchtung\b/ || $subject =~ /\bLicht\b/) ? 1 : 0;
    $takes_singular = 0 if $subject =~ /\bLampen\b/;

    my $temporal = Claude_LocalSummaryTemporalAdverb($hash, $instruction, $command, $devices, $subject, $hasRepeatCue);
    my $repeat   = $hasRepeatCue ? Claude_LocalSummaryRepeatPhrase($hash, $instruction, $command, $subject) : '';

    return "$subject ist$temporal$repeat an." if $command eq 'on' && $takes_singular && $hasRepeatCue;
    return "$subject sind$temporal$repeat an." if $command eq 'on' && $hasRepeatCue;
    return "$subject ist$temporal an." if $command eq 'on' && $takes_singular;
    return "$subject sind$temporal an." if $command eq 'on';
    return "$subject ist$temporal$repeat aus." if $command eq 'off' && $takes_singular && $hasRepeatCue;
    return "$subject sind$temporal$repeat aus." if $command eq 'off' && $hasRepeatCue;
    return "$subject ist$temporal aus." if $command eq 'off' && $takes_singular;
    return "$subject sind$temporal aus." if $command eq 'off';
    return "$subject wurde umgeschaltet." if $command eq 'toggle' && $takes_singular;
    return "$subject wurden umgeschaltet." if $command eq 'toggle';
    return "$subject ist$temporal offen." if $command eq 'open' && $takes_singular;
    return "$subject sind$temporal offen." if $command eq 'open';
    return "$subject ist$temporal geschlossen." if $command eq 'close' && $takes_singular;
    return "$subject sind$temporal geschlossen." if $command eq 'close';
    if ($command eq 'up' || $command eq 'down') {
        my $motionVerb = Claude_LocalSummaryMotionPhrase($hash, $instruction, $command, $subject, $takes_singular);
        my $direction  = Claude_LocalSummaryMotionDirectionPhrase($hash, $instruction, $command, $subject, $takes_singular);
        return "$subject $motionVerb$temporal $direction.";
    }
    return "$subject wurde gestoppt." if $command eq 'stop' && $takes_singular;
    return "$subject wurden gestoppt." if $command eq 'stop';

    if ($command =~ /^(?:pct|bri|brightness|position)\s+(.+)$/) {
        my $value = $1;
        my $setVerb = Claude_LocalSummarySetVerb($hash, $instruction, $command, $subject);
        my $valuePhrase = Claude_LocalSummaryValuePhrase($hash, $instruction, $command, $subject, $value, Claude_LocalSummaryValueUnit($command), ($is_single || $takes_singular));
        return "$subject ist$temporal $valuePhrase $setVerb." if $is_single || $takes_singular;
        return "$subject sind$temporal $valuePhrase $setVerb.";
    }

    if ($command =~ /^(?:desired-temp|temperature|desiredTemperature|temp)\s+(.+)$/) {
        my $value = $1;
        my $setVerb = Claude_LocalSummarySetVerb($hash, $instruction, $command, $subject);
        my $valuePhrase = Claude_LocalSummaryValuePhrase($hash, $instruction, $command, $subject, $value, Claude_LocalSummaryValueUnit($command), ($is_single || $takes_singular));
        return "$subject ist$temporal $valuePhrase $setVerb." if $is_single || $takes_singular;
        return "$subject sind$temporal $valuePhrase $setVerb.";
    }

    my $doneVerb = Claude_LocalSummaryDoneVerb($hash, $instruction, $command, $subject, ($is_single || $takes_singular));
    return "$subject wurde $doneVerb." if $is_single || $takes_singular;
    return "$subject wurden $doneVerb.";
}

sub Claude_ExecuteLocalResolvedBatch {
    my ($hash, $instruction, $devices, $command, $value) = @_;
    return 0 unless $devices && ref($devices) eq 'ARRAY' && @$devices;
    return 0 unless defined $command && $command ne '';

    my $name = $hash->{NAME};
    my @successfulDevices;
    my @successfulCommands;
    my @executedLines;
    my $setSuffix = defined $value && $value ne '' ? "$command $value" : $command;

    for my $device (@$devices) {
        next unless defined $device && $device ne '';
        next unless exists $main::defs{$device};

        if (defined $value && $value ne '') {
            next unless Claude_DeviceSupportsValueForCommand($device, $command, $value);
        } else {
            next unless Claude_DeviceSupportsCommand($device, $command);
        }

        my $setResult = CommandSet(undef, "$device $setSuffix");
        $setResult //= 'ok';
        $setResult = 'ok' if $setResult eq '';

        Log3 $name, 3, "Claude ($name): local resolved set $device $setSuffix -> $setResult";
        next unless $setResult eq 'ok';

        push @successfulDevices,  $device;
        push @successfulCommands, $command;
        push @executedLines, "$device $setSuffix";
    }

    return 0 unless @successfulDevices;

    Claude_RememberControlledDevices($hash, \@successfulDevices);
    Claude_RememberControlBatch($hash, $instruction, \@successfulDevices, \@successfulCommands);

    my $lastCmd = join(', ', @executedLines);
    utf8::encode($lastCmd) if utf8::is_utf8($lastCmd);

    my $summary = Claude_BuildLocalControlSummary($instruction, $setSuffix, \@successfulDevices, $hash);
    my $plain = $summary;
    my $html  = $summary;
    my $ssml  = "<speak>$summary</speak>";

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastCommand',       $lastCmd);
    readingsBulkUpdate($hash, 'lastCommandResult', 'ok');
    readingsBulkUpdate($hash, 'response',          $summary);
    readingsBulkUpdate($hash, 'responsePlain',     $plain);
    readingsBulkUpdate($hash, 'responseHTML',      $html);
    readingsBulkUpdate($hash, 'responseSSML',      $ssml);
    readingsBulkUpdate($hash, 'state',             'ok');
    readingsBulkUpdate($hash, 'lastError',         '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "Claude ($name): Lokale Schnellaufloesung ausgefuehrt: command=$command devices=" . join(', ', @successfulDevices);
    return 1;
}

sub Claude_TryResolveControlLocally {
    my ($hash, $instruction) = @_;
    return 0 unless defined $instruction && $instruction ne '';

    my $name = $hash->{NAME};
    my $logPrefix = "Claude ($name): LocalResolver";
    return 0 unless AttrVal($name, 'localControlResolver', 1);

    my $intentClass = Claude_InferIntentClass($instruction, $hash);
    Log3 $name, 4, "$logPrefix intent=$intentClass instruction='$instruction'";
    if ($intentClass eq 'unsupported') {
        Log3 $name, 4, "$logPrefix abort: unsupported intent";
        return 0;
    }

    my @controlDevices = Claude_GetControlDevices($hash);
    Log3 $name, 4, "$logPrefix controlDevices=" . scalar(@controlDevices);
    unless (@controlDevices) {
        Log3 $name, 4, "$logPrefix abort: no control devices";
        return 0;
    }

    if ($intentClass eq 'referential_followup' && Claude_ExecuteReferentialBatchLocally($hash, $instruction)) {
        Log3 $name, 4, "$logPrefix success: referential followup handled locally";
        return 1;
    }

    my @aliasMatches = Claude_MatchDevicesByAlias($instruction, \@controlDevices);
    my $room = Claude_MatchRoomToken($instruction, \@controlDevices);
    my $type = Claude_MatchDeviceType($instruction, \@controlDevices);

    Log3 $name, 4, "$logPrefix aliasMatches=[" . join(', ', @aliasMatches) . "] aliasCount=" . scalar(@aliasMatches) . " room='$room' type='$type'";

    my @matched;

    if (@aliasMatches == 1) {
        @matched = @aliasMatches;
        Log3 $name, 4, "$logPrefix using single alias match=[" . join(', ', @matched) . "]";
    } else {
        if ($room eq '' && $type eq '') {
            Log3 $name, 4, "$logPrefix abort: neither room nor type matched";
            return 0;
        }
        if (@aliasMatches > 1) {
            Log3 $name, 4, "$logPrefix abort: ambiguous alias matches=[" . join(', ', @aliasMatches) . "]";
            return 0;
        }

        @matched = @controlDevices;

        if ($room ne '') {
            @matched = grep {
                my $roomAttr = AttrVal($_, 'room', '');
                my @rooms = split(/\s*,\s*/, $roomAttr);
                my %roomTokens;

                for my $roomEntry (@rooms) {
                    my $normRoom = Claude_NormalizeText($roomEntry);
                    next unless $normRoom ne '';
                    for my $token (grep { $_ ne '' && length($_) >= 3 } split(/\s+/, $normRoom)) {
                        $roomTokens{$token} = 1;
                    }
                }

                exists $roomTokens{$room};
            } @matched;
            Log3 $name, 4, "$logPrefix after room filter=[" . join(', ', @matched) . "]";
        }

        if ($type ne '') {
            my @beforeType = @matched;
            my @typeChecks;
            @matched = grep {
                my $device = $_;
                my $matches = Claude_DeviceMatchesNormalizedType($device, $type);
                push @typeChecks, $device . '=' . ($matches ? 'match' : 'no-match');
                $matches;
            } @matched;
            Log3 $name, 4, "$logPrefix type filter type='$type' checks=[" . join(', ', @typeChecks) . "]";
            Log3 $name, 4, "$logPrefix after type filter=[" . join(', ', @matched) . "] from before=[" . join(', ', @beforeType) . "]";
        }
    }

    unless (@matched) {
        Log3 $name, 4, "$logPrefix abort: no matched devices after filters";
        return 0;
    }

    my ($command, $value) = ('', '');

    if ($intentClass eq 'device_command') {
        ($command, $value) = Claude_InferLocalCommand($instruction, \@matched);
    } elsif ($intentClass eq 'value_assignment') {
        ($command, $value) = Claude_InferValueCommand($instruction, \@matched);
    }

    Log3 $name, 4, "$logPrefix inferred command='$command' value='$value' matched=[" . join(', ', @matched) . "]";

    if ($command eq '') {
        Log3 $name, 4, "$logPrefix abort: no local command inferred";
        return 0;
    }

    if ($value ne '') {
        for my $device (@matched) {
            unless (Claude_DeviceSupportsValueForCommand($device, $command, $value)) {
                Log3 $name, 4, "$logPrefix abort: device '$device' does not support value command '$command $value'";
                return 0;
            }
        }
    } else {
        unless (Claude_AllDevicesSupportCommand(\@matched, $command)) {
            Log3 $name, 4, "$logPrefix abort: not all matched devices support command '$command'";
            return 0;
        }
    }

    my $ok = Claude_ExecuteLocalResolvedBatch($hash, $instruction, \@matched, $command, $value);
    Log3 $name, 4, "$logPrefix final result=" . ($ok ? 'local-success' : 'local-failed');
    return $ok;
}

sub Claude_RememberControlledDevices {
    my ($hash, $devices) = @_;
    return unless $devices && ref($devices) eq 'ARRAY';

    my %seen;
    my @unique = grep { defined $_ && $_ ne '' && !$seen{$_}++ } @$devices;
    $hash->{LAST_CONTROLLED_DEVICES} = \@unique;
}

sub Claude_RememberControlBatch {
    my ($hash, $instruction, $successfulDevices, $successfulCommands) = @_;
    return unless $hash && ref($hash) eq 'HASH';
    return unless $successfulDevices && ref($successfulDevices) eq 'ARRAY' && @$successfulDevices;

    $hash->{LAST_CONTROL_INSTRUCTION} = $instruction;

    my %seen;
    my @devices = grep { defined $_ && $_ ne '' && !$seen{$_}++ } @$successfulDevices;

    my %cmdCount;
    if ($successfulCommands && ref($successfulCommands) eq 'ARRAY') {
        for my $cmd (@$successfulCommands) {
            next unless defined $cmd && $cmd ne '';
            $cmdCount{$cmd}++;
        }
    }

    my $dominantCommand = '';
    if (%cmdCount) {
        ($dominantCommand) = sort { $cmdCount{$b} <=> $cmdCount{$a} || $a cmp $b } keys %cmdCount;
    }

    $hash->{LAST_CONTROL_BATCH} = {
        instruction => ($instruction // ''),
        command     => $dominantCommand,
        devices     => \@devices,
        count       => scalar(@devices),
    };
}

sub Claude_HasRepeatCue {
    my ($instruction) = @_;
    return 0 unless defined $instruction;

    my $text = Claude_NormalizeText($instruction);
    return 0 if $text eq '';

    return ($text =~ /\b(?:wieder|nochmal|erneut)\b/) ? 1 : 0;
}

sub Claude_IsReferentialFollowupInstruction {
    my ($instruction, $hash) = @_;
    return 0 unless defined $instruction;

    my $text = Claude_NormalizeText($instruction);
    return 0 if $text eq '';

    my $signals = Claude_GetIntentSignals($instruction);
    my $hasPronoun = ($text =~ /\b(?:sie|diese|dieser|dieses|jene|jener|jenes|dieselben|denen)\b/);
    my $hasRepeat  = Claude_HasRepeatCue($instruction);
    my $hasAction  = ($signals->{turn_on} || $signals->{turn_off} || $signals->{toggle} || $signals->{increase} || $signals->{decrease} || $signals->{open_like} || $signals->{close_like} || $signals->{stop});

    return 0 unless $hasAction && ($hasPronoun || $hasRepeat);

    my @controlDevices = ($hash && ref($hash) eq 'HASH') ? Claude_GetControlDevices($hash) : ();
    my @aliasMatches   = @controlDevices ? Claude_MatchDevicesByAlias($instruction, \@controlDevices) : ();
    my $room           = @controlDevices ? Claude_MatchRoomToken($instruction, \@controlDevices) : '';
    my $type           = @controlDevices ? Claude_MatchDeviceType($instruction, \@controlDevices) : '';

    my $hasConcreteTarget = (@aliasMatches || $room ne '' || $type ne '') ? 1 : 0;
    return 0 if $hasConcreteTarget;

    my $batch = ($hash && ref($hash) eq 'HASH') ? $hash->{LAST_CONTROL_BATCH} : undef;
    $batch = undef unless $batch && ref($batch) eq 'HASH';
    return 0 unless $batch && $batch->{devices} && ref($batch->{devices}) eq 'ARRAY' && @{$batch->{devices}};

    return 1;
}

sub Claude_ExpandReferentialInstruction {
    my ($hash, $instruction) = @_;
    return $instruction unless Claude_IsReferentialFollowupInstruction($instruction, $hash);

    my $batch = $hash->{LAST_CONTROL_BATCH};
    return $instruction unless $batch && ref($batch) eq 'HASH';

    my $devices = $batch->{devices};
    return $instruction unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my @parts;
    for my $devName (@$devices) {
        next unless defined $devName && $devName ne '';
        next unless exists $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);
        push @parts, "$alias (intern: $devName)";
    }

    return $instruction unless @parts;

    my $expanded = $instruction . "\n\n";
    $expanded .= "WICHTIGER AUFLOESUNGSKONTEXT: Diese Folgeanweisung bezieht sich auf die gesamte zuletzt erfolgreich gesteuerte Zielmenge, nicht nur auf ein einzelnes Geraet.\n";
    $expanded .= "Letzte Zielmenge mit " . scalar(@parts) . " Geraeten:\n- " . join("\n- ", @parts);

    return $expanded;
}

sub Claude_InferReferentialBatchCommand {
    my ($instruction, $devices) = @_;
    return undef unless defined $instruction;
    return undef unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my @candidates = Claude_GetCandidateCommandsForInstruction($instruction, $devices);
    my $command = Claude_ResolveCommandFromCandidates($devices, \@candidates);

    return $command if defined $command && $command ne '';
    return undef;
}

sub Claude_FinalizeRememberedControlSession {
    my ($hash) = @_;

    my $devices  = delete $hash->{CONTROL_SUCCESSFUL_DEVICES};
    my $commands = delete $hash->{CONTROL_SUCCESSFUL_COMMANDS};
    my $instruction = $hash->{LAST_CONTROL_INSTRUCTION};

    return unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    Claude_RememberControlledDevices($hash, $devices);
    Claude_RememberControlBatch($hash, $instruction, $devices, $commands);

    my $name = $hash->{NAME};
    Log3 $name, 4, "Claude ($name): Finalisiere Control-Session fuer letzte Zielmenge: " . join(', ', @$devices);
}

sub Claude_ExecuteReferentialBatchLocally {
    my ($hash, $instruction) = @_;
    return 0 unless Claude_IsReferentialFollowupInstruction($instruction, $hash);

    my $batch = $hash->{LAST_CONTROL_BATCH};
    return 0 unless $batch && ref($batch) eq 'HASH';

    my %previousBatch = %{$batch};

    my $devices = $batch->{devices};
    return 0 unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my $command = Claude_InferReferentialBatchCommand($instruction, $devices);
    return 0 unless defined $command && $command ne '';

    my $name = $hash->{NAME};
    my @successfulDevices;
    my @successfulCommands;
    my @executedLines;

    my $controlList = AttrVal($name, 'controlList', '');
    my %allowed     = map { $_ => 1 } split(/\s*,\s*/, $controlList);

    for my $device (@$devices) {
        next unless defined $device && $device ne '';
        next unless $allowed{$device};
        next unless exists $main::defs{$device};
        next unless Claude_DeviceSupportsCommand($device, $command);

        my $setResult = CommandSet(undef, "$device $command");
        $setResult //= 'ok';
        $setResult = 'ok' if $setResult eq '';

        Log3 $name, 3, "Claude ($name): local referential batch set $device $command -> $setResult";

        next unless $setResult eq 'ok';

        push @successfulDevices,  $device;
        push @successfulCommands, $command;
        push @executedLines, "$device $command";
    }

    return 0 unless @successfulDevices;

    Claude_RememberControlledDevices($hash, \@successfulDevices);
    Claude_RememberControlBatch($hash, $instruction, \@successfulDevices, \@successfulCommands);

    my $lastCmd = join(', ', @executedLines);
    utf8::encode($lastCmd) if utf8::is_utf8($lastCmd);

    my $summary = Claude_BuildLocalControlSummary(
        $instruction,
        $command,
        \@successfulDevices,
        $hash,
        reference_batch => \%previousBatch
    );

    my $plain = $summary;
    my $html  = $summary;
    my $ssml  = "<speak>$summary</speak>";

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastCommand',       $lastCmd);
    readingsBulkUpdate($hash, 'lastCommandResult', 'ok');
    readingsBulkUpdate($hash, 'response',          $summary);
    readingsBulkUpdate($hash, 'responsePlain',     $plain);
    readingsBulkUpdate($hash, 'responseHTML',      $html);
    readingsBulkUpdate($hash, 'responseSSML',      $ssml);
    readingsBulkUpdate($hash, 'state',             'ok');
    readingsBulkUpdate($hash, 'lastError',         '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "Claude ($name): Referenzielle Folgeanweisung lokal auf Batch aufgeloest: command=$command devices=" . join(', ', @successfulDevices);
    return 1;
}

##############################################################################
# Control-Funktion: Geraet steuern via Claude Tool Use
##############################################################################
sub Claude_SendControl {
    my ($hash, $instruction) = @_;
    my $name = $hash->{NAME};
    my $originalInstruction = $instruction;

    if (AttrVal($name, 'disable', 0)) {
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
        return;
    }

    if (Claude_TryResolveControlLocally($hash, $instruction)) {
        return;
    }

    my $apiKey = AttrVal($name, 'apiKey', '');
    if (!$apiKey) {
        readingsSingleUpdate($hash, 'lastError', 'Kein API Key gesetzt (attr apiKey)', 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): Kein API Key konfiguriert!";
        return;
    }

    my $model      = AttrVal($name, 'model',      'claude-haiku-4-5');
    my $timeout    = AttrVal($name, 'timeout',    30);
    my $maxHistory = int(AttrVal($name, 'maxHistory', 10));
    my $effectiveHistory = $maxHistory < 6 ? 6 : $maxHistory;
    my $maxTokens  = int(AttrVal($name, 'maxTokens',  300));

    Log3 $name, 4, "Claude ($name): Verwende Modell $model";

    # Startindex merken, damit bei Fehlern die gesamte Control-Session
    # sauber aus dem Verlauf entfernt werden kann
    $hash->{CONTROL_START_IDX} = scalar(@{$hash->{CHAT}});
    $hash->{CONTROL_SUCCESSFUL_DEVICES}  = [];
    $hash->{CONTROL_SUCCESSFUL_COMMANDS} = [];
    $instruction = Claude_ExpandReferentialInstruction($hash, $instruction);
    Log3 $name, 4, "Claude ($name): Expandierte Folgeanweisung von '$originalInstruction' zu '$instruction'" if $instruction ne $originalInstruction;

    $hash->{LAST_CONTROL_INSTRUCTION} = $originalInstruction;

    push @{$hash->{CHAT}}, {
        role    => 'user',
        content => [{
            type => 'text',
            text => $instruction
        }]
    };

    Claude_TrimHistory($hash, $effectiveHistory);

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend = $disableHistory
        ? [ $hash->{CHAT}[-1] ]
        : Claude_SanitizeMessagesForApi($hash->{CHAT}, $name);

    if (!$messagesToSend || ref($messagesToSend) ne 'ARRAY' || !@$messagesToSend) {
        my $errMsg = 'Interner Fehler: Keine gueltigen messages fuer Control-Anfrage erzeugt';
        readingsSingleUpdate($hash, 'lastError', $errMsg, 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): $errMsg; CHAT=" . Claude_DebugMessageSummary($hash->{CHAT});
        Claude_RollbackControlSession($hash);
        return;
    }
    Log3 $name, 4, "Claude ($name): Control messages " . Claude_DebugMessageSummary($messagesToSend);

    my $fullSystem = Claude_BuildControlSystemPrompt($hash, include_control_context => 1);

    Log3 $name, 4, "Claude ($name): Effective control history=$effectiveHistory" if $effectiveHistory != $maxHistory;

    # Control-Request an Claude:
    # zusaetzlich zu den Nachrichten werden hier die verfuegbaren Tools
    # fuer set_device und get_device_state mitgeschickt
    my %requestBody = (
        model      => $model,
        max_tokens => $maxTokens,
        messages   => $messagesToSend,
        tools      => Claude_GetControlTools()
    );

    $requestBody{system} = $fullSystem if $fullSystem ne '';
    $requestBody{cache_control} = { type => 'ephemeral' } if AttrVal($name, 'promptCaching', 0);

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        pop @{$hash->{CHAT}};
        delete $hash->{CONTROL_START_IDX};
        return;
    }

    Log3 $name, 4, "Claude ($name): Control-Anfrage " . $jsonBody;

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => Claude_ApiUrl(),
        timeout  => $timeout,
        method   => 'POST',
        header   => Claude_RequestHeaders($apiKey),
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Claude_HandleControlResponse,
    });

    return undef;
}

##############################################################################
# Callback: Antwort auf Control-Anfrage / Tool-Result verarbeiten
##############################################################################
sub Claude_HandleControlResponse {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        readingsSingleUpdate($hash, 'lastError', "HTTP Fehler: $err", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): HTTP Fehler: $err";
        Claude_RollbackControlSession($hash);
        return;
    }

    utf8::downgrade($data, 1);

    my $result = eval { decode_json($data) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Parse Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): JSON Parse Fehler: $@";
        Claude_RollbackControlSession($hash);
        return;
    }

    if (exists $result->{model}) {
        Log3 $name, 4, "Claude ($name): API meldet Modell " . $result->{model};
    }

    if (exists $result->{error}) {
        my $errType = $result->{error}{type}    // 'unknown_error';
        my $errMsg  = $result->{error}{message} // 'Unbekannter API Fehler';
        readingsSingleUpdate($hash, 'lastError', "API Fehler ($errType): $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): API Fehler ($errType): $errMsg";
        Claude_RollbackControlSession($hash);
        return;
    }

    my $contentBlocks = $result->{content} // [];
    my @toolResults;
    my @successfulDevices;
    my @successfulCommands;
    my $hasToolUse = 0;

    for my $part (@$contentBlocks) {
        next unless ref($part) eq 'HASH';
        next unless ($part->{type} // '') eq 'tool_use';

        $hasToolUse = 1;

        my $toolName = $part->{name}  // '';
        my $toolId   = $part->{id}    // '';
        my $input    = $part->{input} // {};
        my $inputJson = eval { encode_json($input) };
        $inputJson = '{json_encode_error}' if $@;
        Log3 $name, 4, "Claude ($name): ToolUse empfangen: name=$toolName id=$toolId input=$inputJson";

        if ($toolName eq 'set_device') {
            my $device  = $input->{device}  // '';
            my $command = $input->{command} // '';

            if (!$device) {
                my $errMsg = "Fehler: Tool set_device ohne device";
                Log3 $name, 2, "Claude ($name): $errMsg";
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => $errMsg
                };
                next;
            }

            if (!$command) {
                my $errMsg = "Fehler: Tool set_device ohne command";
                Log3 $name, 2, "Claude ($name): $errMsg";
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => $errMsg
                };
                next;
            }

            if ($command =~ /[;|`\$\(\)<>\n]/) {
                my $errMsg = "Fehler: Ungueltiger Befehl '$command' (unerlaubte Zeichen)";
                Log3 $name, 2, "Claude ($name): $errMsg";
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => $errMsg
                };
                next;
            }

            my $controlList = AttrVal($name, 'controlList', '');
            my %allowed     = map { $_ => 1 } split(/\s*,\s*/, $controlList);

            if ($allowed{$device} && exists $main::defs{$device}) {
                my ($toolCommandName) = split(/\s+/, $command, 2);

                if (!defined $toolCommandName || $toolCommandName eq '' || !Claude_DeviceSupportsCommand($device, $toolCommandName)) {
                    my $errMsg = "Fehler: Befehl '$command' fuer Geraet '$device' nicht verfuegbar";

                    my $cmdForReading = "$device $command";
                    utf8::encode($cmdForReading) if utf8::is_utf8($cmdForReading);
                    my $resForReading = $errMsg;
                    utf8::encode($resForReading) if utf8::is_utf8($resForReading);

                    readingsBeginUpdate($hash);
                    readingsBulkUpdate($hash, 'lastCommand',       $cmdForReading);
                    readingsBulkUpdate($hash, 'lastCommandResult', $resForReading);
                    readingsEndUpdate($hash, 1);

                    Log3 $name, 2, "Claude ($name): $errMsg";
                    push @toolResults, {
                        type        => 'tool_result',
                        tool_use_id => $toolId,
                        content     => $errMsg
                    };
                    next;
                }

                my ($toolValue) = $command =~ /^\S+\s+(.+)$/;
                if (defined $toolValue && $toolValue ne '' && !Claude_DeviceSupportsValueForCommand($device, $toolCommandName, $toolValue)) {
                    my $errMsg = "Fehler: Wert '$toolValue' fuer Befehl '$toolCommandName' bei Geraet '$device' nicht verfuegbar";

                    my $cmdForReading = "$device $command";
                    utf8::encode($cmdForReading) if utf8::is_utf8($cmdForReading);
                    my $resForReading = $errMsg;
                    utf8::encode($resForReading) if utf8::is_utf8($resForReading);

                    readingsBeginUpdate($hash);
                    readingsBulkUpdate($hash, 'lastCommand',       $cmdForReading);
                    readingsBulkUpdate($hash, 'lastCommandResult', $resForReading);
                    readingsEndUpdate($hash, 1);

                    Log3 $name, 2, "Claude ($name): $errMsg";
                    push @toolResults, {
                        type        => 'tool_result',
                        tool_use_id => $toolId,
                        content     => $errMsg
                    };
                    next;
                }

                my $setResult = CommandSet(undef, "$device $command");
                $setResult //= 'ok';
                $setResult = 'ok' if $setResult eq '';

                my $cmdForReading = "$device $command";
                utf8::encode($cmdForReading) if utf8::is_utf8($cmdForReading);
                my $resForReading = $setResult;
                utf8::encode($resForReading) if utf8::is_utf8($resForReading);

                readingsBeginUpdate($hash);
                readingsBulkUpdate($hash, 'lastCommand',       $cmdForReading);
                readingsBulkUpdate($hash, 'lastCommandResult', $resForReading);
                readingsEndUpdate($hash, 1);

                Log3 $name, 3, "Claude ($name): set $device $command -> $setResult";
                push @successfulDevices, $device if $setResult eq 'ok';
                push @successfulCommands, $command if $setResult eq 'ok';
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => ($setResult eq 'ok' ? "OK: $device $command ausgefuehrt" : "Fehler: $setResult")
                };
            } else {
                my $errMsg = "Fehler: Geraet '$device' nicht in controlList oder nicht vorhanden";

                my $cmdForReading = "$device $command";
                utf8::encode($cmdForReading) if utf8::is_utf8($cmdForReading);
                my $resForReading = $errMsg;
                utf8::encode($resForReading) if utf8::is_utf8($resForReading);

                readingsBeginUpdate($hash);
                readingsBulkUpdate($hash, 'lastCommand',       $cmdForReading);
                readingsBulkUpdate($hash, 'lastCommandResult', $resForReading);
                readingsEndUpdate($hash, 1);

                Log3 $name, 2, "Claude ($name): $errMsg";
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => $errMsg
                };
            }

        } elsif ($toolName eq 'get_device_state') {
            my $device = $input->{device} // '';
            my $stateResult;

            if (!$device) {
                $stateResult = "Fehler: Tool get_device_state ohne device";
            } elsif (exists $main::defs{$device}) {
                my $dev = $main::defs{$device};
                my $traits = Claude_GetDeviceTraits($device);

                $stateResult  = "Geraet: $device\n";
                $stateResult .= "Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";
                $stateResult .= "Status: " . ReadingsVal($device, 'state', 'unbekannt') . "\n";

                my @classes;
                push @classes, 'light'   if $traits->{light};
                push @classes, 'cover'   if $traits->{cover};
                push @classes, 'climate' if $traits->{climate};
                push @classes, 'sensor'  if $traits->{sensor};
                push @classes, 'switch'  if $traits->{switchable} && !$traits->{light};
                $stateResult .= "Klassen: " . join(', ', @classes) . "\n" if @classes;

                if (exists $dev->{READINGS}) {
                    my @blacklist = Claude_GetBlacklist($hash);
                    my @selectedReadings = Claude_GetRelevantReadings($device, max => 6);
                    @selectedReadings = grep { $_ ne 'state' } @selectedReadings;

                    my @compactReadings;
                    for my $reading (@selectedReadings) {
                        next if Claude_IsBlacklisted($reading, @blacklist);
                        next unless exists $dev->{READINGS}{$reading};
                        my $val = $dev->{READINGS}{$reading}{VAL} // '';
                        push @compactReadings, "  $reading: $val";
                    }

                    if (@compactReadings) {
                        $stateResult .= "Wichtige Readings:\n";
                        $stateResult .= join("\n", @compactReadings) . "\n";
                    }
                }
            } else {
                $stateResult = "Fehler: Geraet '$device' nicht gefunden";
            }

            push @toolResults, {
                type        => 'tool_result',
                tool_use_id => $toolId,
                content     => $stateResult
            };

        } else {
            push @toolResults, {
                type        => 'tool_result',
                tool_use_id => $toolId,
                content     => "Fehler: Unbekanntes Tool '$toolName'"
            };
        }
    }

    if ($hasToolUse) {
        if (@successfulDevices) {
            my $sessionDevices  = $hash->{CONTROL_SUCCESSFUL_DEVICES}  ||= [];
            my $sessionCommands = $hash->{CONTROL_SUCCESSFUL_COMMANDS} ||= [];

            push @$sessionDevices,  @successfulDevices;
            push @$sessionCommands, @successfulCommands;

            my %seen;
            @$sessionDevices = grep { defined $_ && $_ ne '' && !$seen{$_}++ } @$sessionDevices;

            Log3 $name, 4, "Claude ($name): Sammle erfolgreiche Geraete fuer laufende Control-Session: " . join(', ', @$sessionDevices);
        }

        push @{$hash->{CHAT}}, {
            role    => 'assistant',
            content => $contentBlocks
        };

        Claude_SendToolResults($hash, \@toolResults);
        return;
    }

    my $responseUnicode = '';
    for my $part (@$contentBlocks) {
        next unless ref($part) eq 'HASH';
        $responseUnicode .= $part->{text} if (($part->{type} // '') eq 'text' && exists $part->{text});
    }

    if (!$responseUnicode) {
        my $stopReason = $result->{stop_reason} // 'UNKNOWN';
        readingsSingleUpdate($hash, 'lastError', "Leere Antwort, stop_reason: $stopReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "Claude ($name): Leere Control-Antwort, stop_reason: $stopReason";
        Claude_RollbackControlSession($hash);
        return;
    }

    push @{$hash->{CHAT}}, {
        role    => 'assistant',
        content => $contentBlocks
    };

    Claude_FinalizeRememberedControlSession($hash);
    delete $hash->{CONTROL_START_IDX};

    my $responseForReading = $responseUnicode;
    utf8::encode($responseForReading) if utf8::is_utf8($responseForReading);

    my $responsePlain = Claude_MarkdownToPlain($responseUnicode);
    utf8::encode($responsePlain) if utf8::is_utf8($responsePlain);

    my $responseHTML = Claude_MarkdownToHTML($responseUnicode);
    utf8::encode($responseHTML) if utf8::is_utf8($responseHTML);

    my $responseSSML = Claude_MarkdownToSSML($responseUnicode);
    utf8::encode($responseSSML) if utf8::is_utf8($responseSSML);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',      $responseForReading);
    readingsBulkUpdate($hash, 'responsePlain', $responsePlain);
    readingsBulkUpdate($hash, 'responseHTML',  $responseHTML);
    readingsBulkUpdate($hash, 'responseSSML',  $responseSSML);
    readingsBulkUpdate($hash, 'chatHistory',   scalar(@{$hash->{CHAT}}));
    readingsBulkUpdate($hash, 'state',         'ok');
    readingsBulkUpdate($hash, 'lastError',     '-');
    readingsEndUpdate($hash, 1);

    Log3 $name, 4, "Claude ($name): Control-Antwort erhalten (" . length($responseUnicode) . " Zeichen)";
    return undef;
}

##############################################################################
# Hilfsfunktion: Tool-Results gesammelt an Claude zurueckschicken
##############################################################################
sub Claude_SendToolResults {
    my ($hash, $toolResults) = @_;
    my $name = $hash->{NAME};

    return unless $toolResults && ref($toolResults) eq 'ARRAY' && @$toolResults;

    push @{$hash->{CHAT}}, {
        role    => 'user',
        content => $toolResults
    };

    my $apiKey    = AttrVal($name, 'apiKey',    '');
    my $model     = AttrVal($name, 'model',     'claude-haiku-4-5');
    my $timeout   = AttrVal($name, 'timeout',   30);
    my $maxTokens = int(AttrVal($name, 'maxTokens', 300));

    Log3 $name, 4, "Claude ($name): Verwende Modell $model";

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend;
    if ($disableHistory) {
        my $startIdx = $hash->{CONTROL_START_IDX} // 0;
        $messagesToSend = [ @{$hash->{CHAT}}[$startIdx..$#{$hash->{CHAT}}] ];
    } else {
        $messagesToSend = Claude_SanitizeMessagesForApi($hash->{CHAT}, $name);
    }

    if (!$messagesToSend || ref($messagesToSend) ne 'ARRAY' || !@$messagesToSend) {
        my $errMsg = 'Interner Fehler: Keine gueltigen messages fuer ToolResults erzeugt';
        readingsSingleUpdate($hash, 'lastError', $errMsg, 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): $errMsg; CHAT=" . Claude_DebugMessageSummary($hash->{CHAT});
        Claude_RollbackControlSession($hash);
        return;
    }
    Log3 $name, 4, "Claude ($name): ToolResult messages " . Claude_DebugMessageSummary($messagesToSend);

    my $fullSystem = Claude_BuildControlSystemPrompt($hash, include_control_context => 0);

    my %requestBody = (
        model      => $model,
        max_tokens => $maxTokens,
        messages   => $messagesToSend,
        tools      => Claude_GetControlTools()
    );

    $requestBody{system} = $fullSystem if $fullSystem ne '';
    $requestBody{cache_control} = { type => 'ephemeral' } if AttrVal($name, 'promptCaching', 0);

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Claude_RollbackControlSession($hash);
        return;
    }

    my @toolIds = map { $_->{tool_use_id} // '?' } @$toolResults;
    my @toolContents = map { ($_->{tool_use_id} // '?') . '=' . ($_->{content} // '') } @$toolResults;
    Log3 $name, 4, "Claude ($name): ToolResults fuer '" . join("', '", @toolIds) . "' gesendet";
    Log3 $name, 4, "Claude ($name): ToolResult Inhalte: " . join(' || ', @toolContents);
    Log3 $name, 4, "Claude ($name): ToolResult Request " . $jsonBody;

    HttpUtils_NonblockingGet({
        url      => Claude_ApiUrl(),
        timeout  => $timeout,
        method   => 'POST',
        header   => Claude_RequestHeaders($apiKey),
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Claude_HandleControlResponse,
    });

    return undef;
}

1;

=pod
=item device
=item summary Anthropic Claude AI integration for FHEM
=item summary_DE Anthropic Claude KI Anbindung fuer FHEM

=begin html

<a name="Claude"></a>
<h3>Claude</h3>
<ul>
  FHEM Modul zur Anbindung der Anthropic Claude API.<br><br>

  <b>Define</b><br>
  <ul><code>define <name> Claude</code></ul><br>

  <b>Attribute</b><br>
  <ul>
    <li><b>apiKey</b> - Anthropic API Key (Pflicht)</li>
    <li><b>model</b> - Claude Modell (Standard: claude-haiku-4-5).
      <code>claude-haiku-4-5</code> ist aktuell das kostenguenstigste
      verfuegbare Claude-Modell und fuer viele typische FHEM-Anwendungen
      eine gute Standardwahl.</li>
    <li><b>maxHistory</b> - Max. Chat-Nachrichten (Standard: 10). Ein kleinerer Wert
      haelt den mitgesendeten Verlauf kompakter, weil weniger fruehere Nachrichten
      erneut an Claude gesendet werden.</li>
    <li><b>maxTokens</b> - Maximale Antwortlaenge. Wenn das Attribut nicht gesetzt ist,
      verwendet das Modul je nach Anfrageart unterschiedliche Fallback-Werte:
      <code>600</code> fuer normale Anfragen wie <b>ask</b> oder <b>askAboutDevices</b>
      sowie <code>300</code> fuer <b>control</b> bzw. Tool Use. Wenn das Attribut
      gesetzt ist, ueberschreibt dieser Wert die jeweiligen Fallbacks. Ein kleinerer
      Wert haelt Antworten kompakter und begrenzt den zu erwartenden Tokenverbrauch,
      kann Antworten aber kuerzer ausfallen lassen.</li>
    <li><b>systemPrompt</b> - Optionaler System-Prompt. Je laenger der Prompt ist,
      desto groesser wird der mitgesendete Kontext pro Anfrage.</li>
    <li><b>timeout</b> - HTTP Timeout in Sekunden (Standard: 30)</li>
    <li><b>disable</b> - Modul deaktivieren</li>
    <li><b>disableHistory</b> - Chat-Verlauf deaktivieren (0/1). Bei 1 wird jede Anfrage
      ohne vorherigen Chat-Verlauf gesendet und als eigenstaendiges Gespraech behandelt.
      Der interne Verlauf bleibt erhalten (fuer resetChat), wird aber nicht an die API uebermittelt.
      Das kann bei vielen Anwendungsfaellen Tokens sparen, reduziert aber den
      Gespraechskontext.</li>
    <li><b>promptCaching</b> - Aktiviert Prompt-Caching in der Claude API (0/1).
      Das ist besonders sinnvoll bei wiederkehrenden Prompts, Geraetekontexten oder
      aehnlichen Anfragen und kann den laufenden Verbrauch reduzieren.</li>
    <li><b>deviceContextMode</b> - Steuert, wie viele Geraeteinformationen bei
      <b>askAboutDevices</b> an Claude gesendet werden.<br>
      <code>compact</code>: sendet pro Geraet nur den Alias, den aktuellen Status
      und bis zu 3 wichtige Readings. Das ist fuer viele typische
      Zusammenfassungen bereits gut ausreichend und haelt den Kontext klein.<br>
      <code>detailed</code>: sendet zusaetzlich den internen Geraetenamen, den Typ
      sowie weitere Attribute wie <code>room</code>, <code>group</code> und
      <code>alias</code>. Das ist ausfuehrlicher und kann bei komplexeren
      Rueckfragen hilfreich sein.</li>
    <li><b>controlContextMode</b> - Steuert, wie viele Informationen fuer den
      <b>control</b>-Befehl an Claude gesendet werden.<br>
      <code>compact</code>: sendet pro Geraet nur Alias, internen Namen und
      aktuellen Status. Das reicht fuer viele einfache Schaltbefehle bereits
      gut aus und haelt den Kontext klein.<br>
      <code>detailed</code>: sendet zusaetzlich eine kompakte Liste typischer
      verfuegbarer Befehle mit. Das hilft Claude bei komplexeren
      Steueranweisungen und kann die Aufloesung freierer Formulierungen
      erleichtern.</li>
    <li><b>localControlResolver</b> - Aktiviert den lokalen Resolver fuer den
      Claude-Hybridbetrieb bei <b>control</b>-Befehlen (0/1, Standard: 1).<br>
      Bei <code>1</code> arbeitet das Modul hybrid: viele einfache und
      eindeutige Steuerbefehle werden direkt in FHEM ausgefuehrt. Dafuer ist in
      diesen Faellen kein zusaetzlicher Claude-API-Aufruf noetig. Das spart im
      Alltag Tokens und damit laufende Kosten, sodass die Nutzung von Claude in
      FHEM fuer typische Steueraufgaben in der Praxis meist gut bezahlbar
      bleibt.<br>
      Komplexe, mehrdeutige oder frei formulierte Anweisungen laufen weiterhin
      automatisch ueber Claude. Bei <code>0</code> wird jeder
      <b>control</b>-Befehl vollstaendig ueber Claude verarbeitet.<br>
      Der lokale Resolver arbeitet bewusst konservativ und uebernimmt nur
      Befehle, die sicher und eindeutig aufloesbar sind. Freiere oder
      mehrdeutige Formulierungen bleiben deshalb beim Claude-Fallback.</li>
    <li><b>readingBlacklist</b> - Leerzeichen-getrennte Liste von
      Reading- oder Befehlsnamen, die nicht an Claude uebermittelt werden.
      Wildcards mit <code>*</code> werden unterstuetzt, z. B.
      <code>R-*</code> oder <code>Wifi_*</code>. Die Blacklist wird auf
      Device-Kontext, Control-Kontext und das Tool
      <code>get_device_state</code> angewendet. Zusaetzlich gibt es eine
      interne Standard-Blacklist fuer technisch wenig hilfreiche Eintraege.</li>
    <li><b>deviceList</b> - Komma-getrennte Geraeteliste fuer askAboutDevices</li>
    <li><b>deviceRoom</b> - Komma-getrennte Raumliste; alle Geraete mit passendem
      FHEM-room-Attribut werden automatisch fuer askAboutDevices verwendet.
      Beispiel: <code>attr ClaudeAI deviceRoom Wohnzimmer,Kueche</code>.
      Kann zusammen mit <b>deviceList</b> verwendet werden.</li>
    <li><b>controlList</b> - Komma-getrennte Liste der Geraete, die Claude per
      Tool Use steuern darf (Pflicht fuer den control-Befehl).
      Alias-Namen und verfuegbare set-Befehle der Geraete werden automatisch
      an Claude uebermittelt, sodass Sprachbefehle mit Alias-Namen und
      passende Befehle automatisch erkannt werden. Eine kompakte und sinnvoll
      begrenzte Liste haelt den gesendeten Kontext ueberschaubar.
      Beispiel: <code>attr ClaudeAI controlList Lampe1,Heizung,Rolladen1</code></li>
  </ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> <Frage> - Textfrage stellen</li>
    <li><b>askWithImage</b> <Bildpfad> <Frage> - Bild + Frage senden</li>
    <li><b>askAboutDevices</b> [<Frage>] - Geraete-Status an Claude uebergeben und Frage stellen</li>
    <li><b>control</b> <Anweisung> - Steuert FHEM-Geraete per Sprachbefehl.
      Im Standard arbeitet das Modul im Claude-Hybridbetrieb (Lokalmodus):
      viele einfache Standardbefehle werden direkt lokal in FHEM ausgefuehrt,
      waehrend Claude komplexere oder freier formulierte Anweisungen
      uebernimmt. Dadurch sind typische Schaltvorgaenge oft ohne zusaetzlichen
      API-Aufruf moeglich, was im Alltag Tokens und damit Kosten sparen kann.
      Beispiel: <code>set ClaudeAI control Mach die Wohnzimmerlampe an</code>.
      Nur Geraete aus <b>controlList</b> duerfen gesteuert werden.</li>
    <li><b>resetChat</b> - Chat-Verlauf loeschen</li>
  </ul><br>

  <b>Get</b><br>
  <ul>
    <li><b>chatHistory</b> - Chat-Verlauf anzeigen</li>
  </ul><br>

  <b>Readings</b><br>
  <ul>
    <li><b>response</b> - Letzte Textantwort von Claude (Roh-Markdown)</li>
    <li><b>responsePlain</b> - Letzte Textantwort, Markdown-Syntax entfernt (reiner Text, ideal fuer Sprachausgabe, Telegram, Notify)</li>
    <li><b>responseHTML</b> - Letzte Textantwort, Markdown in HTML konvertiert (ideal fuer Tablet-UI, Web-Frontends)</li>
    <li><b>responseSSML</b> - Letzte Textantwort, fuer Sprachausgabe bereinigt und als SSML aufbereitet</li>
    <li><b>state</b> - Aktueller Status</li>
    <li><b>lastError</b> - Letzter Fehler</li>
    <li><b>chatHistory</b> - Anzahl der Nachrichten im Chat-Verlauf</li>
    <li><b>lastCommand</b> - Letzter ausgefuehrter set-Befehl (z.B. <code>Lampe1 on</code>)</li>
    <li><b>lastCommandResult</b> - Ergebnis des letzten set-Befehls (<code>ok</code> oder Fehlermeldung)</li>
  </ul><br>
</ul>

=end html
=cut
