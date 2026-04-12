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
#                    weniger Verlauf spart Tokens und ist guenstiger
#   maxTokens      - Maximale Antwortlaenge (Default: 600 fuer ask, 300 fuer control);
#                    kleinere Werte begrenzen Antwortkosten und sind meist guenstiger
#   systemPrompt   - Optionaler System-Prompt; laengere Prompts kosten mehr Tokens
#                    und werden dadurch teurer
#   timeout        - HTTP Timeout in Sekunden (Standard: 30)
#   promptCaching  - Prompt-Caching via Claude API aktivieren (0/1);
#                    wiederkehrende Prompts und Kontexte koennen dadurch guenstiger werden
#   deviceContextMode  - Kontext fuer askAboutDevices: compact oder detailed;
#                        compact ist guenstiger, detailed liefert mehr Infos, ist aber teurer
#   controlContextMode - Kontext fuer control: compact oder detailed;
#                        compact ist guenstiger, detailed liefert mehr Infos, ist aber teurer
#   deviceList     - Komma-getrennte Liste der Geraete fuer askAboutDevices
#   deviceRoom     - Komma-getrennte Raumliste; Geraete mit passendem room-Attribut
#                    werden automatisch fuer askAboutDevices verwendet
#   controlList    - Komma-getrennte Liste der Geraete, die Claude steuern darf
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

my $MODULE_VERSION = '1.1.2';

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
    for my $part (@$contentBlocks) {
        next unless ref($part) eq 'HASH';
        $responseUnicode .= $part->{text} if (($part->{type} // '') eq 'text' && exists $part->{text});
    }

    if (!$responseUnicode) {
        my $stopReason = $result->{stop_reason} // 'UNKNOWN';
        readingsSingleUpdate($hash, 'lastError', "Leere Antwort, stop_reason: $stopReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "Claude ($name): Leere Antwort erhalten, stop_reason: $stopReason";
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
        'bmp'  => 'image/bmp',
    );

    return $mimeTypes{$ext} // 'image/jpeg';
}

##############################################################################
# FHEM Device-Kontext fuer Claude aufbauen
##############################################################################
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

    my @importantReadings = qw(
        state
        power
        pct
        bri
        temperature
        humidity
        battery
        contact
        motion
        presence
        desired-temp
        measured-temp
        mode
    );
    my $contextMode = AttrVal($name, 'deviceContextMode', 'detailed');

    my $context = "Aktueller Status der Smart-Home Geraete:\n";

    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $dev   = $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);

        Log3 $name, 4, "Claude ($name): Alias " . $alias;

        $context .= "\nGeraet: $alias";
        $context .= " (intern: $devName)" if $contextMode ne 'compact';
        $context .= "\n";
        $context .= "  Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n" if $contextMode ne 'compact';
        $context .= "  Status: " . ReadingsVal($devName, 'state', 'unbekannt') . "\n";

        if (exists $dev->{READINGS}) {
            my @compactReadings;
            my $maxReadings = $contextMode eq 'compact' ? 3 : scalar(@importantReadings);
            for my $reading (@importantReadings) {
                next unless exists $dev->{READINGS}{$reading};
                next if $reading eq 'state';
                my $val = $dev->{READINGS}{$reading}{VAL} // '';
                push @compactReadings, "    $reading: $val";
                last if @compactReadings >= $maxReadings;
            }

            if (@compactReadings) {
                $context .= "  Wichtige Readings:\n";
                $context .= join("\n", @compactReadings) . "\n";
            }
        }

        if ($contextMode ne 'compact') {
            for my $attrName (qw(room group alias)) {
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

    my @preferred = qw(on off toggle pct bri dimUp dimDown open close up down stop lock unlock);
    my %preferred = map { $_ => 1 } @preferred;
    my @blacklist = qw(attrTemplate associate rename intervals off-till off-till-overnight on-till on-till-overnight on-for-timer off-for-timer);
    my %blackset  = map { $_ => 1 } @blacklist;
    my $contextMode = AttrVal($name, 'controlContextMode', 'detailed');

    my $context = "Verfuegbare Geraete zum Steuern:\n";
    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);

        my $state = ReadingsVal($devName, 'state', 'unbekannt');

        my $setListRaw = main::getAllSets($devName) // '';
        my (@preferredCmds, @otherCmds);

        for my $entry (split(/\s+/, $setListRaw)) {
            my ($cmdName) = split(/:/, $entry, 2);
            next unless $cmdName;
            next if $blackset{$cmdName};

            if ($preferred{$cmdName}) {
                push @preferredCmds, $cmdName;
            } elsif ($contextMode ne 'compact' && @otherCmds < 3) {
                push @otherCmds, $cmdName;
            }
        }

        my @cmds = (@preferredCmds, @otherCmds);
        my %seen;
        @cmds = grep { !$seen{$_}++ } @cmds;
        my $cmdsStr = @cmds ? join(', ', @cmds) : 'unbekannt';

        if ($contextMode eq 'compact') {
            $context .= "  $alias (intern: $devName, Status: $state)\n";
        } else {
            $context .= "  $alias (intern: $devName, Status: $state) -- Befehle: $cmdsStr\n";
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

sub Claude_RememberControlledDevices {
    my ($hash, $devices) = @_;
    return unless $devices && ref($devices) eq 'ARRAY';

    my %seen;
    my @unique = grep { defined $_ && $_ ne '' && !$seen{$_}++ } @$devices;
    $hash->{LAST_CONTROLLED_DEVICES} = \@unique;
}

sub Claude_RememberControlBatch {
    my ($hash, $instruction, $successfulDevices, $successfulCommands) = @_;
    return unless $successfulDevices && ref($successfulDevices) eq 'ARRAY' && @$successfulDevices;

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

sub Claude_IsReferentialFollowupInstruction {
    my ($instruction) = @_;
    return 0 unless defined $instruction;

    my $text = lc($instruction);
    $text =~ s/[[:punct:]]/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;

    return 0 if $text eq '';

    my $hasPronoun = ($text =~ /\b(?:sie|die|der|das|diese|dieser|dieses|jene|jener|jenes|dieselben|den|dem|denen)\b/);
    my $hasRepeat  = ($text =~ /\b(?:wieder|nochmal|erneut)\b/);
    my $hasAction  = ($text =~ /\b(?:an|aus|ein|einmachen|einschalten|anmachen|off|on|ausschalten|ausmachen|toggle|umschalten|dimmen|heller|dunkler)\b/);

    my $hasConcreteTarget = ($text =~ /\b(?:wohnzimmer|kueche|küche|bad|badezimmer|flur|schlafzimmer|wintergarten|lampe|lampen|licht|lichter|led|decke|spiegel|lavalampe)\b/);

    return 0 if $hasConcreteTarget;
    return 1 if $hasAction && ($hasPronoun || $hasRepeat);

    return 0;
}

sub Claude_ExpandReferentialInstruction {
    my ($hash, $instruction) = @_;
    return $instruction unless Claude_IsReferentialFollowupInstruction($instruction);

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
    my ($instruction) = @_;
    return undef unless defined $instruction;

    my $text = lc($instruction);

    return 'off'    if $text =~ /\b(?:aus|ausschalten|ausmachen|off)\b/;
    return 'on'     if $text =~ /\b(?:an|anmachen|einschalten|einmachen|on)\b/;
    return 'toggle' if $text =~ /\b(?:toggle|umschalten)\b/;

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
    return 0 unless Claude_IsReferentialFollowupInstruction($instruction);

    my $command = Claude_InferReferentialBatchCommand($instruction);
    return 0 unless defined $command && $command ne '';

    my $batch = $hash->{LAST_CONTROL_BATCH};
    return 0 unless $batch && ref($batch) eq 'HASH';

    my $devices = $batch->{devices};
    return 0 unless $devices && ref($devices) eq 'ARRAY' && @$devices;

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

    my $summary;
    if ($command eq 'off') {
        $summary = "Die zuletzt gesteuerte Geraetegruppe ist jetzt aus.";
    } elsif ($command eq 'on') {
        $summary = "Die zuletzt gesteuerte Geraetegruppe ist jetzt an.";
    } elsif ($command eq 'toggle') {
        $summary = "Die zuletzt gesteuerte Geraetegruppe wurde umgeschaltet.";
    } else {
        $summary = "Die zuletzt gesteuerte Geraetegruppe wurde ausgefuehrt.";
    }

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

    if (Claude_ExecuteReferentialBatchLocally($hash, $instruction)) {
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
                push @successfulDevices, $device;
                push @successfulCommands, $command;
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => "OK: $device $command ausgefuehrt"
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
                my @importantReadings = qw(
                    state
                    power
                    pct
                    bri
                    temperature
                    humidity
                    battery
                    contact
                    motion
                    presence
                    desired-temp
                    measured-temp
                    mode
                );

                $stateResult  = "Geraet: $device\n";
                $stateResult .= "Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";
                $stateResult .= "Status: " . ReadingsVal($device, 'state', 'unbekannt') . "\n";

                if (exists $dev->{READINGS}) {
                    my @compactReadings;
                    my %important = map { $_ => 1 } @importantReadings;

                    for my $reading (@importantReadings) {
                        next unless exists $dev->{READINGS}{$reading};
                        next if $reading eq 'state';
                        my $val = $dev->{READINGS}{$reading}{VAL} // '';
                        push @compactReadings, "  $reading: $val";
                    }

                    if (@compactReadings < 5) {
                        for my $reading (sort keys %{$dev->{READINGS}}) {
                            next if $reading eq 'state';
                            next if $important{$reading};
                            my $val = $dev->{READINGS}{$reading}{VAL} // '';
                            push @compactReadings, "  $reading: $val";
                            last if @compactReadings >= 5;
                        }
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
    <li><b>model</b> - Claude Modell (Standard: claude-haiku-4-5)</li>
    <li><b>maxHistory</b> - Max. Chat-Nachrichten (Standard: 10). Ein kleinerer Wert
      spart Input-Tokens und ist guenstiger, weil weniger Verlauf bei jeder Anfrage
      erneut an Claude gesendet wird.</li>
    <li><b>maxTokens</b> - Maximale Antwortlaenge. Default: 600 fuer normale Anfragen,
      300 fuer control/tool use. Ein kleinerer Wert begrenzt die Antwortkosten und ist
      guenstiger, kann Antworten aber kuerzer ausfallen lassen.</li>
    <li><b>systemPrompt</b> - Optionaler System-Prompt. Je laenger der Prompt ist,
      desto mehr Input-Tokens fallen bei jeder Anfrage an und desto teurer wird es.</li>
    <li><b>timeout</b> - HTTP Timeout in Sekunden (Standard: 30)</li>
    <li><b>disable</b> - Modul deaktivieren</li>
    <li><b>disableHistory</b> - Chat-Verlauf deaktivieren (0/1). Bei 1 wird jede Anfrage
      ohne vorherigen Chat-Verlauf gesendet und als eigenstaendiges Gespraech behandelt.
      Der interne Verlauf bleibt erhalten (fuer resetChat), wird aber nicht an die API uebermittelt.
      Das spart Input-Tokens und ist oft deutlich guenstiger, kann aber den
      Gespraechskontext verschlechtern.</li>
    <li><b>promptCaching</b> - Aktiviert Prompt-Caching in der Claude API (0/1).
      Das ist besonders sinnvoll bei wiederkehrenden Prompts, Geraetekontexten oder
      aehnlichen Anfragen und kann die Kosten deutlich senken.</li>
    <li><b>deviceContextMode</b> - Steuert, wie viele Geraeteinformationen bei
      <b>askAboutDevices</b> an Claude gesendet werden.<br>
      <code>compact</code>: sendet pro Geraet nur den Alias, den aktuellen Status
      und bis zu 3 wichtige Readings. Das spart Tokens, ist guenstiger und fuer
      einfache Zusammenfassungen meist ausreichend.<br>
      <code>detailed</code>: sendet zusaetzlich den internen Geraetenamen, den Typ
      sowie weitere Attribute wie <code>room</code>, <code>group</code> und
      <code>alias</code>. Das ist ausfuehrlicher, aber auch teurer.</li>
    <li><b>controlContextMode</b> - Steuert, wie viele Informationen fuer den
      <b>control</b>-Befehl an Claude gesendet werden.<br>
      <code>compact</code>: sendet pro Geraet nur Alias, internen Namen und
      aktuellen Status. Das spart Tokens, ist guenstiger und reicht oft fuer
      einfache Schaltbefehle.<br>
      <code>detailed</code>: sendet zusaetzlich eine kompakte Liste typischer
      verfuegbarer Befehle mit. Das hilft Claude bei komplexeren
      Steueranweisungen, ist aber teurer.</li>
    <li><b>deviceList</b> - Komma-getrennte Geraeteliste fuer askAboutDevices</li>
    <li><b>deviceRoom</b> - Komma-getrennte Raumliste; alle Geraete mit passendem
      FHEM-room-Attribut werden automatisch fuer askAboutDevices verwendet.
      Beispiel: <code>attr ClaudeAI deviceRoom Wohnzimmer,Kueche</code>.
      Kann zusammen mit <b>deviceList</b> verwendet werden.</li>
    <li><b>controlList</b> - Komma-getrennte Liste der Geraete, die Claude per
      Tool Use steuern darf (Pflicht fuer den control-Befehl).
      Alias-Namen und verfuegbare set-Befehle der Geraete werden automatisch
      an Claude uebermittelt, sodass Sprachbefehle mit Alias-Namen und
      passende Befehle automatisch erkannt werden. Mehr Geraete und mehr
      Kontext bedeuten in der Regel auch mehr Input-Tokens und damit hoehere Kosten.
      Beispiel: <code>attr ClaudeAI controlList Lampe1,Heizung,Rolladen1</code></li>
  </ul><br>

  <b>Set</b><br>
  <ul>
    <li><b>ask</b> <Frage> - Textfrage stellen</li>
    <li><b>askWithImage</b> <Bildpfad> <Frage> - Bild + Frage senden</li>
    <li><b>askAboutDevices</b> [<Frage>] - Geraete-Status an Claude uebergeben und Frage stellen</li>
    <li><b>control</b> <Anweisung> - Claude steuert FHEM-Geraete eigenstaendig per
      Tool Use. Beispiel: <code>set ClaudeAI control Mach die Wohnzimmerlampe an</code>.
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
  </ul>
</ul>

=end html
=cut
