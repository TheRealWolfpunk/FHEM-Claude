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
#   maxHistory     - Maximale Anzahl Chat-Nachrichten (Standard: 20)
#   systemPrompt   - Optionaler System-Prompt
#   timeout        - HTTP Timeout in Sekunden (Standard: 30)
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
#   state              - Aktueller Status
#   lastError          - Letzter Fehler
#   chatHistory        - Anzahl der Nachrichten im Verlauf
#   lastCommand        - Letzter ausgefuehrter set-Befehl
#   lastCommandResult  - Ergebnis des letzten set-Befehls
#
##############################################################################

# Versionshistorie:
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

my $MODULE_VERSION = '1.0.2';

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
        'timeout ' .
        'disable:0,1 ' .
        'disableHistory:0,1 ' .
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
    readingsSingleUpdate($hash, 'chatHistory',       0,             0);
    readingsSingleUpdate($hash, 'lastError',         '-',           0);
    readingsSingleUpdate($hash, 'lastCommand',       '-',           0);
    readingsSingleUpdate($hash, 'lastCommandResult', '-',           0);

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
    my $maxHistory = AttrVal($name, 'maxHistory', 20);

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
        max_tokens => 4096,
        messages   => $messagesToSend
    );

    $requestBody{system} = $fullSystem if $fullSystem ne '';

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

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',      $responseForReading);
    readingsBulkUpdate($hash, 'responsePlain', $responsePlain);
    readingsBulkUpdate($hash, 'responseHTML',  $responseHTML);
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

    my $context = "Aktueller Status der Smart-Home Geraete:\n";

    for my $devName (@devices) {
        next unless exists $main::defs{$devName};
        my $dev   = $main::defs{$devName};
        my $alias = AttrVal($devName, 'alias', $devName);

        Log3 $name, 3, "Claude ($name): Alias " . $alias;

        $context .= "\nGeraet: $alias (intern: $devName)\n";
        $context .= "  Typ: " . ($dev->{TYPE} // 'unbekannt') . "\n";
        $context .= "  Status: " . ReadingsVal($devName, 'state', 'unbekannt') . "\n";

        if (exists $dev->{READINGS}) {
            my @compactReadings;
            for my $reading (@importantReadings) {
                next unless exists $dev->{READINGS}{$reading};
                next if $reading eq 'state';
                my $val = $dev->{READINGS}{$reading}{VAL} // '';
                push @compactReadings, "    $reading: $val";
            }

            if (@compactReadings) {
                $context .= "  Wichtige Readings:\n";
                $context .= join("\n", @compactReadings) . "\n";
            }
        }

        for my $attrName (qw(room group alias)) {
            my $attrVal = AttrVal($devName, $attrName, '');
            $context .= "  $attrName: $attrVal\n" if $attrVal;
        }

        Log3 $name, 3, "Claude ($name): " . $alias . ": " . $context;
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
            } elsif (@otherCmds < 3) {
                push @otherCmds, $cmdName;
            }
        }

        my @cmds = (@preferredCmds, @otherCmds);
        my %seen;
        @cmds = grep { !$seen{$_}++ } @cmds;
        my $cmdsStr = @cmds ? join(', ', @cmds) : 'unbekannt';

        $context .= "  $alias (intern: $devName, Status: $state) -- Befehle: $cmdsStr\n";
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
            description => 'Fuehrt einen FHEM set-Befehl auf einem Geraet aus, z.B. on, off oder einen numerischen Wert',
            input_schema => {
                type       => 'object',
                properties => {
                    device  => { type => 'string', description => 'FHEM Geraetename (intern)' },
                    command => { type => 'string', description => 'Der set-Befehl, z.B. on, off, 21' }
                },
                required => ['device', 'command']
            }
        },
        {
            name        => 'get_device_state',
            description => 'Liest den aktuellen Status und alle Readings eines FHEM-Geraets',
            input_schema => {
                type       => 'object',
                properties => {
                    device => { type => 'string', description => 'FHEM Geraetename (intern)' }
                },
                required => ['device']
            }
        }
    ];
}

##############################################################################
# Hilfsfunktion: Gueltigen Claude-Chat fuer Tool-Use rekonstruieren
##############################################################################
sub Claude_SanitizeMessagesForApi {
    my ($messages) = @_;
    return [] unless $messages && ref($messages) eq 'ARRAY';

    my @sanitized;
    my @pendingToolIds;

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
            } else {
                pop @sanitized;
            }

            @pendingToolIds = ();
            next;
        }

        push @sanitized, $msg;
    }

    pop @sanitized if @pendingToolIds;
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
}

##############################################################################
# Control-Funktion: Geraet steuern via Claude Tool Use
##############################################################################
sub Claude_SendControl {
    my ($hash, $instruction) = @_;
    my $name = $hash->{NAME};

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
    my $maxHistory = AttrVal($name, 'maxHistory', 20);

    # Startindex merken, damit bei Fehlern die gesamte Control-Session
    # sauber aus dem Verlauf entfernt werden kann
    $hash->{CONTROL_START_IDX} = scalar(@{$hash->{CHAT}});

    push @{$hash->{CHAT}}, {
        role    => 'user',
        content => [{
            type => 'text',
            text => $instruction
        }]
    };

    Claude_TrimHistory($hash, $maxHistory);

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend = $disableHistory
        ? [ $hash->{CHAT}[-1] ]
        : Claude_SanitizeMessagesForApi($hash->{CHAT});

    my $systemPrompt   = AttrVal($name, 'systemPrompt', '');
    my $controlContext = Claude_BuildControlContext($hash);

    my $fullSystem = '';
    $fullSystem .= $systemPrompt   if $systemPrompt;
    $fullSystem .= "\n\n"          if $systemPrompt && $controlContext;
    $fullSystem .= $controlContext if $controlContext;

    # Control-Request an Claude:
    # zusaetzlich zu den Nachrichten werden hier die verfuegbaren Tools
    # fuer set_device und get_device_state mitgeschickt
    my %requestBody = (
        model      => $model,
        max_tokens => 4096,
        messages   => $messagesToSend,
        tools      => Claude_GetControlTools()
    );

    $requestBody{system} = $fullSystem if $fullSystem ne '';

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
    my $hasToolUse = 0;

    for my $part (@$contentBlocks) {
        next unless ref($part) eq 'HASH';
        next unless ($part->{type} // '') eq 'tool_use';

        $hasToolUse = 1;

        my $toolName = $part->{name}  // '';
        my $toolId   = $part->{id}    // '';
        my $input    = $part->{input} // {};

        if ($toolName eq 'set_device') {
            my $device  = $input->{device}  // '';
            my $command = $input->{command} // '';

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

            if (exists $main::defs{$device}) {
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

    delete $hash->{CONTROL_START_IDX};

    my $responseForReading = $responseUnicode;
    utf8::encode($responseForReading) if utf8::is_utf8($responseForReading);

    my $responsePlain = Claude_MarkdownToPlain($responseUnicode);
    utf8::encode($responsePlain) if utf8::is_utf8($responsePlain);

    my $responseHTML = Claude_MarkdownToHTML($responseUnicode);
    utf8::encode($responseHTML) if utf8::is_utf8($responseHTML);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'response',      $responseForReading);
    readingsBulkUpdate($hash, 'responsePlain', $responsePlain);
    readingsBulkUpdate($hash, 'responseHTML',  $responseHTML);
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

    my $apiKey  = AttrVal($name, 'apiKey',  '');
    my $model   = AttrVal($name, 'model',   'claude-haiku-4-5');
    my $timeout = AttrVal($name, 'timeout', 30);

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend;
    if ($disableHistory) {
        my $startIdx = $hash->{CONTROL_START_IDX} // 0;
        $messagesToSend = [ @{$hash->{CHAT}}[$startIdx..$#{$hash->{CHAT}}] ];
    } else {
        $messagesToSend = Claude_SanitizeMessagesForApi($hash->{CHAT});
    }

    my $systemPrompt   = AttrVal($name, 'systemPrompt', '');
    my $controlContext = Claude_BuildControlContext($hash);

    my $fullSystem = '';
    $fullSystem .= $systemPrompt   if $systemPrompt;
    $fullSystem .= "\n\n"          if $systemPrompt && $controlContext;
    $fullSystem .= $controlContext if $controlContext;

    my %requestBody = (
        model      => $model,
        max_tokens => 4096,
        messages   => $messagesToSend,
        tools      => Claude_GetControlTools()
    );

    $requestBody{system} = $fullSystem if $fullSystem ne '';

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON Encode Fehler: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Claude_RollbackControlSession($hash);
        return;
    }

    my @toolIds = map { $_->{tool_use_id} // '?' } @$toolResults;
    Log3 $name, 4, "Claude ($name): ToolResults fuer '" . join("', '", @toolIds) . "' gesendet";

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
    <li><b>maxHistory</b> - Max. Chat-Nachrichten (Standard: 20)</li>
    <li><b>systemPrompt</b> - Optionaler System-Prompt</li>
    <li><b>timeout</b> - HTTP Timeout in Sekunden (Standard: 30)</li>
    <li><b>disable</b> - Modul deaktivieren</li>
    <li><b>disableHistory</b> - Chat-Verlauf deaktivieren (0/1). Bei 1 wird jede Anfrage
      ohne vorherigen Chat-Verlauf gesendet und als eigenstaendiges Gespraech behandelt.
      Der interne Verlauf bleibt erhalten (fuer resetChat), wird aber nicht an die API uebermittelt.</li>
    <li><b>deviceList</b> - Komma-getrennte Geraeteliste fuer askAboutDevices</li>
    <li><b>deviceRoom</b> - Komma-getrennte Raumliste; alle Geraete mit passendem
      FHEM-room-Attribut werden automatisch fuer askAboutDevices verwendet.
      Beispiel: <code>attr ClaudeAI deviceRoom Wohnzimmer,Kueche</code>.
      Kann zusammen mit <b>deviceList</b> verwendet werden.</li>
    <li><b>controlList</b> - Komma-getrennte Liste der Geraete, die Claude per
      Tool Use steuern darf (Pflicht fuer den control-Befehl).
      Alias-Namen und verfuegbare set-Befehle der Geraete werden automatisch
      an Claude uebermittelt, sodass Sprachbefehle mit Alias-Namen und
      passende Befehle automatisch erkannt werden.
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
    <li><b>state</b> - Aktueller Status</li>
    <li><b>lastError</b> - Letzter Fehler</li>
    <li><b>chatHistory</b> - Anzahl der Nachrichten im Chat-Verlauf</li>
    <li><b>lastCommand</b> - Letzter ausgefuehrter set-Befehl (z.B. <code>Lampe1 on</code>)</li>
    <li><b>lastCommandResult</b> - Ergebnis des letzten set-Befehls (<code>ok</code> oder Fehlermeldung)</li>
  </ul>
</ul>

=end html
=cut
