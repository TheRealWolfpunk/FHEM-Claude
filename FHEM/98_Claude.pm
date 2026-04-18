########################################################################################
#
#  98_Claude.pm
#
#  FHEM smart home intelligence control/chat module for Anthropic Claude AI
#
#  https://github.com/TheRealWolfpunk/FHEM-Claude
#
########################################################################################
#
#  This programm is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
########################################################################################

# Version history:
# 1.3.3 - 2026-04-18  Change: chat now routes more selectively into control mode;
#                          prompt-caching beta header is only sent when promptCaching
#                          is enabled; device/context handling improved
# 1.3.2 - 2026-04-17  New: additional Claude metadata and more robust
#                          evaluation of optional API fields; extended
#                          token/cache readings can be shown or hidden
#                          via attribute
# 1.3.1 - 2026-04-17  New: instance-specific attribute <InstanceName>_Instructions
#                          for device-specific Claude instructions in device
#                          and control context; logging cleaned up
# 1.3.0 - 2026-04-15  New: chat command for universal messages
#                          (general questions, device status and control
#                          in a single command, ideal for Telegram integration);
#                          new controlRoom attribute analogous to deviceRoom for
#                          controllable devices; new token readings
#                          promptTokenCount, candidatesTokenCount,
#                          totalTokenCount
# 1.2.0 - 2026-04-13  New: readingBlacklist attribute with wildcard support
#                          for device/control context and get_device_state;
#                          additionally the comment attribute from devices
#                          is included in device and control context
# 1.1.0 - 2026-04-12  New: Claude hybrid operation (local mode) with
#                          localControlResolver; many simple and
#                          unambiguous control commands are executed
#                          locally in FHEM, while complex or
#                          ambiguous instructions still go
#                          through Claude
# 1.0.7 - 2026-04-12  Perf/Fix: control prompts and tool result rounds further
#                          compacted; effective control history dynamically
#                          limited; batch context for multi-step tool use
#                          is only finalized after the session completes
#                          to avoid target set errors
# 1.0.6 - 2026-04-12  Fix: follow-up instructions with pronouns made more robust;
#                          the last control action is remembered as a batch and
#                          instructions are rewritten and executed locally for
#                          the target set before the API call
# 1.0.5 - 2026-04-12  Fix/Perf: control requests hardened against empty messages and
#                          parameters; control responses shortened by default;
#                          additional debug logs for reference context and
#                          tool use integrated
# 1.0.4 - 2026-04-12  Perf: token usage further reduced; smaller defaults for
#                          maxHistory/maxTokens, optional prompt caching,
#                          more compact tool definitions, plus optional
#                          sparse/detailed contexts for askAboutDevices
#                          and control
# 1.0.3 - 2026-04-11  New: added responseSSML reading for speech output
# 1.0.2 - 2026-04-11  Perf: token usage reduced for home automation;
#                          askAboutDevices, control and get_device_state
#                          contexts limited to compact but practical
#                          core information
# 1.0.1 - 2026-04-11  Fix: corrected tool use/tool result handling for Anthropic;
#                          multiple tool_use blocks are now answered
#                          collectively and incomplete historical
#                          tool turns are cleaned up before API requests
# 1.0.0 - 2026-04-11  New: forked from 98_Gemini.pm; migrated from Google Gemini API
#                          to Anthropic Claude API; module name, docs, endpoints,
#                          request/response handling and function calling adapted
#                          to Claude Tool Use

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use MIME::Base64;

my $MODULE_VERSION = '1.3.3';

##############################################################################
# Module initialization: register define/set/get/attr handlers and attr list
##############################################################################
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
        'disable:1,0 ' .
        'disableHistory:1,0 ' .
        'promptCaching:1,0 ' .
        'showAdvancedReadings:1,0 ' .
        'deviceContextMode:compact,detailed ' .
        'controlContextMode:compact,detailed ' .
        'localControlResolver:1,0 ' .
        'readingBlacklist:textField-long ' .
        'deviceList:textField-long ' .
        'controlList:textField-long ' .
        'controlRoom:textField-long ' .
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


##############################################################################
# Helper function: check whether advanced readings are enabled
##############################################################################
sub Claude_HasAdvancedTokenReadingsEnabled {
    my ($hash) = @_;
    return 1 unless $hash && ref($hash) eq 'HASH';

    my $name = $hash->{NAME};
    return AttrVal($name, 'showAdvancedReadings', 0) ? 1 : 0;
}

##############################################################################
# Helper function: return the list of optional advanced readings
##############################################################################
sub Claude_GetAdvancedReadingNames {
    return (
        'lastRequestModel',
        'lastRequestType',
        'lastRequestWasLocal',
        'lastApiCallUsedTools',
        'toolUseCount',
        'toolSetDeviceCount',
        'toolGetDeviceStateCount',
        'responseId',
        'responseType',
        'responseRole',
        'stopReason',
        'stopSequence',
        'stopDetails',
        'serviceTier',
        'inferenceGeo',
        'candidatesTokenCount',
        'promptTokenCount',
        'totalTokenCount',
        'cacheCreationInputTokens',
        'cacheReadInputTokens',
        'cacheCreationEphemeral5mInputTokens',
        'cacheCreationEphemeral1hInputTokens'
    );
}

##############################################################################
# Helper function: clear optional advanced readings
##############################################################################
sub Claude_ClearAdvancedTokenReadings {
    my ($hash) = @_;
    return unless $hash && ref($hash) eq 'HASH';

    my $name = $hash->{NAME};
    for my $reading (Claude_GetAdvancedReadingNames()) {
        CommandDeleteReading(undef, "$name $reading");
    }

    return;
}

##############################################################################
# Define function: initialize a Claude device instance and default readings
##############################################################################
sub Claude_Define {
    my ($hash, $def) = @_;
    my @args = split('[ \t]+', $def);

    return "Usage: define <name> Claude" if (@args != 2);

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
    if (Claude_HasAdvancedTokenReadingsEnabled($hash)) {
        my %advancedDefaults = (
            lastRequestModel                    => '-',
            lastRequestType                     => '-',
            lastRequestWasLocal                 => '0',
            lastApiCallUsedTools                => '0',
            toolUseCount                        => '0',
            toolSetDeviceCount                  => '0',
            toolGetDeviceStateCount             => '0',
            responseId                          => '-',
            responseType                        => '-',
            responseRole                        => '-',
            stopReason                          => '-',
            stopSequence                        => '-',
            stopDetails                         => '-',
            serviceTier                         => '-',
            inferenceGeo                        => '-',
            candidatesTokenCount                => '-',
            promptTokenCount                    => '-',
            totalTokenCount                     => '-',
            cacheCreationInputTokens            => '-',
            cacheReadInputTokens                => '-',
            cacheCreationEphemeral5mInputTokens => '-',
            cacheCreationEphemeral1hInputTokens => '-',
        );
        for my $reading (Claude_GetAdvancedReadingNames()) {
            readingsSingleUpdate($hash, $reading, $advancedDefaults{$reading}, 0);
        }
    } else {
        Claude_ClearAdvancedTokenReadings($hash);
    }
    $hash->{LAST_CONTROLLED_DEVICES} = [];
    $hash->{LAST_CONTROL_BATCH}      = undef;

    if (!defined AttrVal($name, 'localControlResolver', undef)) {
        CommandAttr(undef, "$name localControlResolver 1");
    }

    addToAttrList($hash->{NAME} . "_Instructions:textField-long", "Claude");

    Log3 $name, 3, "Claude ($name): Defined";
    return undef;
}

##############################################################################
# Undefine function: clean up a Claude device instance
##############################################################################
sub Claude_Undefine {
    my ($hash, $name) = @_;
    return undef;
}

##############################################################################
# Attribute function: validate attributes and manage derived readings
##############################################################################
sub Claude_Attr {
    my ($cmd, $name, $attr, $value) = @_;
    if (($cmd eq 'set' || $cmd eq 'del') && $attr eq $name . '_Instructions') {
        return "Attribute $attr is not supported on the Claude instance itself";
    }
    if ($cmd eq 'set' && $attr eq 'timeout') {
        return "timeout must be a positive number" unless ($value =~ /^\d+$/ && $value > 0);
    }
    if ($cmd eq 'set' && $attr eq 'maxTokens') {
        return "maxTokens must be a positive number" unless ($value =~ /^\d+$/ && $value > 0);
    }
    if ($attr eq 'showAdvancedReadings') {
        my $hash = $defs{$name};
        return undef unless $hash && ref($hash) eq 'HASH';

        if ($cmd eq 'set') {
            if ($value) {
                my %advancedDefaults = (
                    lastRequestModel                    => '-',
                    lastRequestType                     => '-',
                    lastRequestWasLocal                 => '0',
                    lastApiCallUsedTools                => '0',
                    toolUseCount                        => '0',
                    toolSetDeviceCount                  => '0',
                    toolGetDeviceStateCount             => '0',
                    responseId                          => '-',
                    responseType                        => '-',
                    responseRole                        => '-',
                    stopReason                          => '-',
                    stopSequence                        => '-',
                    stopDetails                         => '-',
                    serviceTier                         => '-',
                    inferenceGeo                        => '-',
                    candidatesTokenCount                => '-',
                    promptTokenCount                    => '-',
                    totalTokenCount                     => '-',
                    cacheCreationInputTokens            => '-',
                    cacheReadInputTokens                => '-',
                    cacheCreationEphemeral5mInputTokens => '-',
                    cacheCreationEphemeral1hInputTokens => '-',
                );

                readingsBeginUpdate($hash);
                for my $reading (Claude_GetAdvancedReadingNames()) {
                    readingsBulkUpdate($hash, $reading, $advancedDefaults{$reading});
                }
                readingsEndUpdate($hash, 1);
            } else {
                Claude_ClearAdvancedTokenReadings($hash);
            }
        } elsif ($cmd eq 'del') {
            Claude_ClearAdvancedTokenReadings($hash);
        }
    }
    return undef;
}

##############################################################################
# Set function: dispatch user commands such as ask/chat/control/resetChat
##############################################################################
sub Claude_Set {
    my ($hash, $name, $cmd, @args) = @_;

    return "\"set $name\" needs at least one argument" unless defined($cmd);

    if ($cmd eq 'ask') {
        return "Usage: set $name ask <question>" unless @args;
        my $question = join(' ', @args);
        Claude_SendRequest($hash, $question, undef, undef, 'ask');
        return undef;

    } elsif ($cmd eq 'askWithImage') {
        return "Usage: set $name askWithImage <imagePath> <question>" unless @args >= 2;
        my $imagePath = $args[0];
        my $question  = join(' ', @args[1..$#args]);
        return "Image file not found: $imagePath" unless -f $imagePath;
        Claude_SendRequest($hash, $question, $imagePath, undef, 'askWithImage');
        return undef;

    } elsif ($cmd eq 'askAboutDevices') {
        my $question      = @args ? join(' ', @args) : 'Gib mir eine Zusammenfassung aller Geraete und ihres aktuellen Status.';
        my $deviceContext = Claude_BuildDeviceContext($hash);
        return Claude_HandleMissingDeviceContext($hash, 'askAboutDevices') unless $deviceContext;
        Claude_SendRequest($hash, $question, undef, $deviceContext, 'askAboutDevices');
        return undef;

    } elsif ($cmd eq 'chat') {
        return "Usage: set $name chat <message>" unless @args;
        my $message = join(' ', @args);
        my @controlDevices = Claude_GetControlDevices($hash);
        my $deviceContext = Claude_BuildDeviceContext($hash);

        if (@controlDevices && Claude_ChatLooksLikeControlIntent($hash, $message)) {
            Claude_SendControl($hash, $message, $deviceContext);
        } else {
            Claude_SendRequest($hash, $message, undef, $deviceContext || undef, 'chat');
        }
        return undef;

    } elsif ($cmd eq 'control') {
        return "Usage: set $name control <instruction>" unless @args;
        my @controlDevices = Claude_GetControlDevices($hash);
        return "Error: neither controlList nor controlRoom is set" unless @controlDevices;
        my $instruction = join(' ', @args);
        Claude_SendControl($hash, $instruction, undef);
        return undef;

    } elsif ($cmd eq 'resetChat') {
        $hash->{CHAT} = [];
        $hash->{LAST_CONTROLLED_DEVICES} = [];
        $hash->{LAST_CONTROL_BATCH}      = undef;
        delete $hash->{LAST_CONTROL_INSTRUCTION};
        delete $hash->{CONTROL_START_IDX};
        delete $hash->{CONTROL_SUCCESSFUL_DEVICES};
        delete $hash->{CONTROL_SUCCESSFUL_COMMANDS};
        delete $hash->{CHAT_EXTRA_CONTEXT};
        readingsSingleUpdate($hash, 'chatHistory', 0, 1);
        readingsSingleUpdate($hash, 'state', 'chat reset', 1);
        Log3 $name, 3, "Claude ($name): Chat history reset";
        return undef;

    } else {
        return "Unknown argument $cmd, choose one of ask:textField askWithImage:textField askAboutDevices:textField chat:textField control:textField resetChat:noArg";
    }
}

##############################################################################
# Get function: return module information such as chat history
##############################################################################
sub Claude_Get {
    my ($hash, $name, $cmd, @args) = @_;

    if ($cmd eq 'chatHistory') {
        my $history = $hash->{CHAT};
        my $output  = "Chat-Verlauf (" . scalar(@$history) . " entries):\n";
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
# Helper function: prepare message for display
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
            push @partsText, '[Image]';
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
# Helper function: limit chat history
##############################################################################
sub Claude_MessageHasToolUse {
    my ($msg) = @_;
    return 0 unless $msg && ref($msg) eq 'HASH';
    return 0 unless ref($msg->{content}) eq 'ARRAY';

    for my $part (@{$msg->{content}}) {
        next unless ref($part) eq 'HASH';
        return 1 if (($part->{type} // '') eq 'tool_use');
    }

    return 0;
}

##############################################################################
# Helper function: detect whether a message contains tool results
##############################################################################
sub Claude_MessageHasToolResult {
    my ($msg) = @_;
    return 0 unless $msg && ref($msg) eq 'HASH';
    return 0 unless ref($msg->{content}) eq 'ARRAY';

    for my $part (@{$msg->{content}}) {
        next unless ref($part) eq 'HASH';
        return 1 if (($part->{type} // '') eq 'tool_result');
    }

    return 0;
}

##############################################################################
# Helper function: preserve complete tool-use turns while trimming history
##############################################################################
sub Claude_MessageIsToolTurnStart {
    my ($msg) = @_;
    return Claude_MessageHasToolUse($msg) ? 1 : 0;
}

##############################################################################
# Helper function: detect whether a message starts a tool-result turn
##############################################################################
sub Claude_MessageIsToolTurnResult {
    my ($msg) = @_;
    return Claude_MessageHasToolResult($msg) ? 1 : 0;
}

##############################################################################
# Helper function: preserve complete tool-use turns while trimming history
##############################################################################
sub Claude_TrimHistory {
    my ($hash, $maxHistory) = @_;
    return unless $hash && ref($hash) eq 'HASH';
    return unless exists $hash->{CHAT} && ref($hash->{CHAT}) eq 'ARRAY';

    $maxHistory = int($maxHistory // 0);
    $maxHistory = 1 if $maxHistory < 1;

    my $chat = $hash->{CHAT};
    return unless @$chat;

    my @segments;
    my $idx = 0;

    while ($idx <= $#$chat) {
        my $msg = $chat->[$idx];

        if (!defined $msg || ref($msg) ne 'HASH') {
            push @segments, [ $idx, $idx ];
            $idx++;
            next;
        }

        if (
            Claude_MessageIsToolTurnStart($msg) &&
            $idx + 1 <= $#$chat &&
            defined $chat->[$idx + 1] &&
            ref($chat->[$idx + 1]) eq 'HASH' &&
            Claude_MessageIsToolTurnResult($chat->[$idx + 1])
        ) {
            push @segments, [ $idx, $idx + 1 ];
            $idx += 2;
            next;
        }

        push @segments, [ $idx, $idx ];
        $idx++;
    }

    if (@segments > $maxHistory) {
        my $keepStartSegmentIdx = @segments - $maxHistory;
        my $keepFrom = $segments[$keepStartSegmentIdx][0];
        splice(@$chat, 0, $keepFrom) if $keepFrom > 0;
    }

    while (@$chat) {
        my $first = $chat->[0];

        if (!defined $first || ref($first) ne 'HASH') {
            shift @$chat;
            next;
        }

        last if ($first->{role} // '') eq 'user';

        if (
            @$chat >= 2 &&
            Claude_MessageIsToolTurnStart($chat->[0]) &&
            defined $chat->[1] &&
            ref($chat->[1]) eq 'HASH' &&
            Claude_MessageIsToolTurnResult($chat->[1])
        ) {
            splice(@$chat, 0, 2);
        } else {
            shift @$chat;
        }
    }

    while (@$chat && Claude_MessageIsToolTurnResult($chat->[0])) {
        shift @$chat;
    }

    while (@$chat) {
        my $last = $chat->[-1];
        last unless defined $last && ref($last) eq 'HASH';

        if (Claude_MessageIsToolTurnStart($last)) {
            pop @$chat;
            next;
        }

        last;
    }

    return;
}

##############################################################################
# Helper function: Claude API request header
##############################################################################
sub Claude_RequestHeaders {
    my ($apiKey, %opts) = @_;

    my @headers = (
        "Content-Type: application/json",
        "Accept: application/json",
        "anthropic-version: 2023-06-01",
    );

    push @headers, "anthropic-beta: prompt-caching-2024-07-31" if $opts{prompt_caching};
    push @headers, "x-api-key: $apiKey";

    return join("\r\n", @headers);
}

##############################################################################
# Helper function: URL for the Claude Messages API
##############################################################################
sub Claude_ApiUrl {
    return 'https://api.anthropic.com/v1/messages';
}

##############################################################################
# Helper function: check whether prompt caching is enabled
##############################################################################
sub Claude_HasPromptCachingEnabled {
    my ($hash) = @_;
    return 0 unless $hash && ref($hash) eq 'HASH';

    my $name = $hash->{NAME};
    return AttrVal($name, 'promptCaching', 0) ? 1 : 0;
}

##############################################################################
# Helper function: return prompt caching configuration for Anthropic requests
##############################################################################
sub Claude_GetPromptCacheControl {
    my ($hash) = @_;
    return undef unless Claude_HasPromptCachingEnabled($hash);

    return { type => 'ephemeral' };
}

##############################################################################
# Helper function: normalize a system prompt/string into Claude content blocks
##############################################################################
sub Claude_BuildSystemBlocks {
    my ($systemText, %opts) = @_;

    return undef unless defined $systemText && $systemText ne '';

    my $cacheControl = $opts{cache_control};
    my %block = (
        type => 'text',
        text => $systemText,
    );

    $block{cache_control} = $cacheControl if $cacheControl && ref($cacheControl) eq 'HASH';
    return [ \%block ];
}

##############################################################################
# Helper function: update metadata/token readings from Claude responses
##############################################################################
sub Claude_UpdateResponseMetadataReadings {
    my ($hash, $result, %opts) = @_;
    return unless $hash && ref($hash) eq 'HASH';

    $result ||= {};
    my $usage = (ref($result->{usage}) eq 'HASH') ? $result->{usage} : {};

    my $inputTokens         = $usage->{input_tokens};
    my $outputTokens        = $usage->{output_tokens};
    my $cacheCreationTokens = $usage->{cache_creation_input_tokens};
    my $cacheReadTokens     = $usage->{cache_read_input_tokens};
    my $cacheCreation       = (ref($usage->{cache_creation}) eq 'HASH') ? $usage->{cache_creation} : {};
    my $cache5mTokens       = $cacheCreation->{ephemeral_5m_input_tokens};
    my $cache1hTokens       = $cacheCreation->{ephemeral_1h_input_tokens};
    my $stopDetails         = $result->{stop_details};
    my $stopDetailsString   = defined $stopDetails ? eval { encode_json($stopDetails) } : undef;
    $stopDetailsString      = defined $stopDetails ? "$stopDetails" : undef if defined $stopDetails && !defined $stopDetailsString;
    my $serviceTierValue    = defined $result->{service_tier}  ? $result->{service_tier}  : $usage->{service_tier};
    my $inferenceGeoValue   = defined $result->{inference_geo} ? $result->{inference_geo} : $usage->{inference_geo};

    my $hasAnyTokenCount = (defined $inputTokens || defined $outputTokens || defined $cacheCreationTokens) ? 1 : 0;
    my $totalTokens = 0;
    $totalTokens += $inputTokens         if defined $inputTokens;
    $totalTokens += $outputTokens        if defined $outputTokens;
    $totalTokens += $cacheCreationTokens if defined $cacheCreationTokens;

    my $lastRequestType  = defined $opts{request_type}     ? $opts{request_type}     : '-';
    my $lastRequestModel = defined $opts{request_model}    ? $opts{request_model}    : ($result->{model} // '-');
    my $lastWasLocal     = defined $opts{was_local}        ? $opts{was_local}        : 0;
    my $usedTools        = defined $opts{used_tools}       ? $opts{used_tools}       : 0;
    my $toolUseCount     = defined $opts{tool_use_count}   ? $opts{tool_use_count}   : 0;
    my $toolSetCount     = defined $opts{tool_set_count}   ? $opts{tool_set_count}   : 0;
    my $toolGetStateCount= defined $opts{tool_get_count}   ? $opts{tool_get_count}   : 0;
    my $showAdvancedTokenReadings = Claude_HasAdvancedTokenReadingsEnabled($hash);

    if ($showAdvancedTokenReadings) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'promptTokenCount',         defined $inputTokens         ? $inputTokens         : '-');
        readingsBulkUpdate($hash, 'candidatesTokenCount',     defined $outputTokens        ? $outputTokens        : '-');
        readingsBulkUpdate($hash, 'totalTokenCount',          $hasAnyTokenCount ? $totalTokens : '-');
        readingsBulkUpdate($hash, 'cacheCreationInputTokens', defined $cacheCreationTokens ? $cacheCreationTokens : '-');
        readingsBulkUpdate($hash, 'cacheReadInputTokens',     defined $cacheReadTokens     ? $cacheReadTokens     : '-');
        readingsBulkUpdate($hash, 'stopReason',               defined $result->{stop_reason}   ? $result->{stop_reason}   : '-');
        readingsBulkUpdate($hash, 'stopSequence',             defined $result->{stop_sequence} ? $result->{stop_sequence} : '-');
        readingsBulkUpdate($hash, 'stopDetails',              defined $stopDetailsString       ? $stopDetailsString       : '-');
        readingsBulkUpdate($hash, 'responseId',               defined $result->{id}            ? $result->{id}            : '-');
        readingsBulkUpdate($hash, 'responseType',             defined $result->{type}          ? $result->{type}          : '-');
        readingsBulkUpdate($hash, 'responseRole',             defined $result->{role}          ? $result->{role}          : '-');
        readingsBulkUpdate($hash, 'serviceTier',              defined $serviceTierValue         ? $serviceTierValue         : '-');
        readingsBulkUpdate($hash, 'inferenceGeo',             defined $inferenceGeoValue        ? $inferenceGeoValue        : '-');
        readingsBulkUpdate($hash, 'cacheCreationEphemeral5mInputTokens', defined $cache5mTokens ? $cache5mTokens : '-');
        readingsBulkUpdate($hash, 'cacheCreationEphemeral1hInputTokens', defined $cache1hTokens ? $cache1hTokens : '-');
        readingsBulkUpdate($hash, 'lastRequestModel',         defined $lastRequestModel        ? $lastRequestModel        : '-');
        readingsBulkUpdate($hash, 'lastRequestType',          defined $lastRequestType         ? $lastRequestType         : '-');
        readingsBulkUpdate($hash, 'lastRequestWasLocal',      $lastWasLocal ? '1' : '0');
        readingsBulkUpdate($hash, 'lastApiCallUsedTools',     $usedTools ? '1' : '0');
        readingsBulkUpdate($hash, 'toolUseCount',             $toolUseCount);
        readingsBulkUpdate($hash, 'toolSetDeviceCount',       $toolSetCount);
        readingsBulkUpdate($hash, 'toolGetDeviceStateCount',  $toolGetStateCount);
        readingsEndUpdate($hash, 1);
    } else {
        Claude_ClearAdvancedTokenReadings($hash);
    }

    return;
}

##############################################################################
# Main function: send request to the Claude API
##############################################################################
sub Claude_SendRequest {
    my ($hash, $question, $imagePath, $deviceContext, $requestType) = @_;
    my $name = $hash->{NAME};
    $requestType = defined $requestType && $requestType ne ''
        ? $requestType
        : ($imagePath ? 'askWithImage' : ($deviceContext ? 'askAboutDevices' : 'ask'));

    # Module disabled? Then do not execute a request
    if (AttrVal($name, 'disable', 0)) {
        readingsSingleUpdate($hash, 'state', 'disabled', 1);
        return;
    }

    my $apiKey = AttrVal($name, 'apiKey', '');
    if (!$apiKey) {
        readingsSingleUpdate($hash, 'lastError', 'No API key set (attr apiKey)', 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): No API key configured!";
        return;
    }

    my $model      = AttrVal($name, 'model',      'claude-haiku-4-5');
    my $timeout    = AttrVal($name, 'timeout',    30);
    my $maxHistory = int(AttrVal($name, 'maxHistory', 10));
    my $maxTokens  = int(AttrVal($name, 'maxTokens',  600));
    my $cacheControl = Claude_GetPromptCacheControl($hash);
    my $showAdvancedTokenReadings = Claude_HasAdvancedTokenReadingsEnabled($hash);

    if ($showAdvancedTokenReadings) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'lastRequestType',      $requestType);
        readingsBulkUpdate($hash, 'lastRequestModel',     $model);
        readingsBulkUpdate($hash, 'lastRequestWasLocal',  '0');
        readingsBulkUpdate($hash, 'lastApiCallUsedTools', '0');
        readingsBulkUpdate($hash, 'toolUseCount',         '0');
        readingsBulkUpdate($hash, 'toolSetDeviceCount',   '0');
        readingsBulkUpdate($hash, 'toolGetDeviceStateCount', '0');
        readingsEndUpdate($hash, 1);
    } else {
        Claude_ClearAdvancedTokenReadings($hash);
    }

    Log3 $name, 4, "Claude ($name): Using model $model";

    # Claude expects content as a content array with text and optional image blocks
    my @content;

    if ($imagePath) {
        my $mimeType = Claude_GetMimeType($imagePath);
        if (!$mimeType) {
            readingsSingleUpdate($hash, 'lastError', "Unsupported image format: $imagePath (allowed: jpg, jpeg, png, gif, webp)", 1);
            readingsSingleUpdate($hash, 'state', 'error', 1);
            Log3 $name, 2, "Claude ($name): Unsupported image format: $imagePath";
            return;
        }
        open(my $fh, '<', $imagePath) or do {
            readingsSingleUpdate($hash, 'lastError', "Cannot read image: $imagePath", 1);
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
        Log3 $name, 4, "Claude ($name): Image loaded: $imagePath ($mimeType)";
    }

    push @content, {
        type => 'text',
        text => $question
    };

    # Add user message to local history
    push @{$hash->{CHAT}}, {
        role    => 'user',
        content => \@content
    };

    # Limit history to the maximum length and ensure
    # that there is no invalid assistant turn at the beginning
    Claude_TrimHistory($hash, $maxHistory);

    # Optionally, history can be disabled for API requests.
    # In that case only the last message is sent to Claude.
    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend = $disableHistory
        ? [ $hash->{CHAT}[-1] ]
        : Claude_SanitizeMessagesForApi($hash->{CHAT}, $name);

    # systemPrompt and optional deviceContext are combined into
    # a single system text for Claude
    my $systemPrompt = AttrVal($name, 'systemPrompt', '');
    my $fullSystem   = '';
    $fullSystem .= $systemPrompt  if $systemPrompt;
    $fullSystem .= "\n\n"         if $systemPrompt && $deviceContext;
    $fullSystem .= $deviceContext if $deviceContext;
    my $systemBlocks = Claude_BuildSystemBlocks($fullSystem, cache_control => $cacheControl);

    # Build the Claude messages request.
    # Unlike Gemini, the system prompt and messages
    # are in separate fields.
    my %requestBody = (
        model      => $model,
        max_tokens => $maxTokens,
        messages   => $messagesToSend
    );

    $requestBody{system} = $systemBlocks if $systemBlocks;

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON encode error: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        pop @{$hash->{CHAT}};
        return;
    }

    Log3 $name, 4, "Claude ($name): Request " . $jsonBody;

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => Claude_ApiUrl(),
        timeout  => $timeout,
        method   => 'POST',
        header   => Claude_RequestHeaders($apiKey, prompt_caching => Claude_HasPromptCachingEnabled($hash)),
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Claude_HandleResponse,
    });

    return undef;
}

##############################################################################
# Callback: process response from Claude
##############################################################################
sub Claude_HandleResponse {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        readingsSingleUpdate($hash, 'lastError', "HTTP error: $err", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): HTTP error: $err";
        pop @{$hash->{CHAT}};
        return;
    }

    Log3 $name, 5, "Claude ($name): Raw response: $data";

    my $result = eval { decode_json($data) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON parse error: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): JSON parse error: $@";
        pop @{$hash->{CHAT}};
        return;
    }

    Claude_UpdateResponseMetadataReadings(
        $hash,
        $result,
        request_type  => ReadingsVal($name, 'lastRequestType', 'ask'),
        request_model => ReadingsVal($name, 'lastRequestModel', AttrVal($name, 'model', 'claude-haiku-4-5')),
        was_local     => 0,
        used_tools    => 0,
        tool_use_count => 0,
        tool_set_count => 0,
        tool_get_count => 0
    );

    if (exists $result->{model}) {
        Log3 $name, 4, "Claude ($name): API reports model " . $result->{model};
    }

    if (exists $result->{error}) {
        my $errType = $result->{error}{type}    // 'unknown_error';
        my $errMsg  = $result->{error}{message} // 'Unknown API error';
        readingsSingleUpdate($hash, 'lastError', "API error ($errType): $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): API error ($errType): $errMsg";
        pop @{$hash->{CHAT}};
        return;
    }

    # Claude returns the actual response as a list of content blocks
    my $contentBlocks = (ref($result->{content}) eq 'ARRAY') ? $result->{content} : [];
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
        if ($stopReason eq 'tool_use') {
            my $errMsg = "Unexpected tool_use stop in non-control request";
            readingsSingleUpdate($hash, 'lastError', $errMsg, 1);
            readingsSingleUpdate($hash, 'state', 'error', 1);
            Log3 $name, 2, "Claude ($name): $errMsg";
            pop @{$hash->{CHAT}};
            return;
        }

        my $types = %contentTypes ? join(', ', sort keys %contentTypes) : 'none';
        my $errMsg = "Claude response contained no text block (stop_reason: $stopReason, content types: $types)";
        readingsSingleUpdate($hash, 'lastError', $errMsg, 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "Claude ($name): $errMsg";
        pop @{$hash->{CHAT}};
        return;
    }

    # Store the assistant response in full for multi-turn conversations
    push @{$hash->{CHAT}}, {
        role    => 'assistant',
        content => $contentBlocks
    };
    Claude_TrimHistory($hash, int(AttrVal($name, 'maxHistory', 10)));

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

    Log3 $name, 4, "Claude ($name): Response received (" . length($responseUnicode) . " characters)";
    return undef;
}

##############################################################################
# Helper function: convert Markdown to plain text
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
# Helper function: convert Markdown to HTML
##############################################################################
sub Claude_EscapeHtml {
    my ($text) = @_;
    return '' unless defined $text;

    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&#39;/g;

    return $text;
}

##############################################################################
# Helper function: convert Markdown to HTML
##############################################################################
sub Claude_MarkdownToHTML {
    my ($text) = @_;
    return '' unless defined $text;

    $text = Claude_EscapeHtml($text);

    $text =~ s/```[^\n]*\n(.*?)```/<pre><code>$1<\/code><\/pre>/gms;
    $text =~ s/\*\*(.+?)\*\*/<b>$1<\/b>/gs;
    $text =~ s/__(.+?)__/<b>$1<\/b>/gs;
    $text =~ s/\*(.+?)\*/<i>$1<\/i>/gs;
    $text =~ s/_(.+?)_/<i>$1<\/i>/gs;
    $text =~ s/`(.+?)`/<code>$1<\/code>/gs;
    $text =~ s/^#{6}\s+(.+)$/<h6>$1<\/h6>/gm;
    $text =~ s/^#{5}\s+(.+)$/<h5>$1<\/h5>/gm;
    $text =~ s/^#{4}\s+(.+)$/<h4>$1<\/h4>/gm;
    $text =~ s/^#{3}\s+(.+)$/<h3>$1<\/h3>/gm;
    $text =~ s/^#{2}\s+(.+)$/<h2>$1<\/h2>/gm;
    $text =~ s/^#\s+(.+)$/<h1>$1<\/h1>/gm;
    $text =~ s/((?:^[\-\*]\s+.+\n?)+)/my $block = $1; $block =~ s{^[\-\*]\s+(.+)$}{<li>$1<\/li>}gm; "<ul>$block<\/ul>"/gme;
    $text =~ s/^(?:---|\*\*\*)\s*$/<hr>/gm;
    $text =~ s/\n(?!<(?:ul|\/ul|li|\/li|h[1-6]|\/h[1-6]|pre|\/pre|code|\/code|hr))/<br>\n/g;

    return $text;
}

##############################################################################
# Helper function: convert response to SSML for speech output
##############################################################################
sub Claude_EscapeSsml {
    my ($text) = @_;
    return '' unless defined $text;

    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&apos;/g;

    return $text;
}

##############################################################################
# Helper function: convert response to SSML for speech output
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
    $text = Claude_EscapeSsml($text);

    return "<speak>$text</speak>";
}

##############################################################################
# Helper function: determine MIME type from file extension
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
# Helper functions for the blacklist of readings/commands
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

##############################################################################
# Helper function: match strings against simple wildcard patterns
##############################################################################
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

##############################################################################
# Helper function: check whether a reading/command matches the blacklist
##############################################################################
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
# Build FHEM device context for Claude
##############################################################################
##############################################################################
# Helper function: choose relevant readings for compact device context output
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

##############################################################################
# Helper function: build the askAboutDevices device context for Claude
##############################################################################
sub Claude_HandleMissingDeviceContext {
    my ($hash, $requestType) = @_;
    return 'Error: invalid Claude device instance' unless $hash && ref($hash) eq 'HASH';

    my $name = $hash->{NAME} // 'Claude';
    $requestType = defined $requestType && $requestType ne '' ? $requestType : 'askAboutDevices';

    my $errMsg = "Error: no devices configured for $requestType (set attribute deviceList and/or deviceRoom)";
    my $showAdvancedTokenReadings = Claude_HasAdvancedTokenReadingsEnabled($hash);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastError', $errMsg);
    readingsBulkUpdate($hash, 'state', 'error');
    if ($showAdvancedTokenReadings) {
        readingsBulkUpdate($hash, 'lastRequestType', $requestType);
        readingsBulkUpdate($hash, 'lastRequestWasLocal', '0');
        readingsBulkUpdate($hash, 'lastApiCallUsedTools', '0');
        readingsBulkUpdate($hash, 'toolUseCount', '0');
        readingsBulkUpdate($hash, 'toolSetDeviceCount', '0');
        readingsBulkUpdate($hash, 'toolGetDeviceStateCount', '0');
    }
    readingsEndUpdate($hash, 1);
    Claude_ClearAdvancedTokenReadings($hash) unless $showAdvancedTokenReadings;

    Log3 $name, 2, "Claude ($name): $errMsg";
    return $errMsg;
}

##############################################################################
# Helper function: build the askAboutDevices device context for Claude
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
            next if $devName eq $name;
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
            next if $devName eq $name;
            unless ($seen{$devName}) {
                push @devices, $devName;
                $seen{$devName} = 1;
            }
        }
    }

    return '' unless @devices;

    my $contextMode = AttrVal($name, 'deviceContextMode', 'detailed');

    my $context = "Aktueller Status der Smarthome Geraete:\n";
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

            my @attributes = ('room', 'group', 'alias', 'comment', $hash->{NAME} . '_Instructions', 'model', 'subType', 'genericDeviceType');
            for my $attrName (@attributes) {
                my $attrVal = AttrVal($devName, $attrName, '');
                $context .= "  $attrName: $attrVal\n" if $attrVal;
            }
        }

        Log3 $name, 5, "Claude ($name): Device context built for $alias";
    }

    return $context;
}

##############################################################################
# Helper function: build device context for the control command
##############################################################################
sub Claude_GetControlDevices {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my %seen;
    my @devices;

    my $controlRoom = AttrVal($name, 'controlRoom', '');
    if ($controlRoom) {
        my @rooms = split(/\s*,\s*/, $controlRoom);
        for my $devName (sort keys %main::defs) {
            next if $devName eq $name;
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

    my $controlList = AttrVal($name, 'controlList', '');
    $controlList = join(',', sort keys %main::defs) if $controlList eq '*';
    if ($controlList) {
        for my $devName (split(/\s*,\s*/, $controlList)) {
            next unless defined $devName && $devName ne '';
            next if $devName eq $name;
            unless ($seen{$devName}) {
                push @devices, $devName;
                $seen{$devName} = 1;
            }
        }
    }

    return grep { exists $main::defs{$_} } @devices;
}

##############################################################################
# Helper function: build device context for the control command
##############################################################################
sub Claude_BuildControlContext {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @devices = Claude_GetControlDevices($hash);
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
        my $claudeInstructions = AttrVal($devName, $name . '_Instructions', '');

        if ($contextMode eq 'compact') {
            $context .= "  $alias (intern: $devName, Status: $state, Klassen: $capsStr)";
            $context .= " -- Allgemeine Beschreibung: $comment" if $comment;
            $context .= " -- Anweisungen fuer Claude: $claudeInstructions" if $claudeInstructions;
            $context .= "\n";
        } else {
            $context .= "  $alias (intern: $devName, Status: $state, Klassen: $capsStr)";
            $context .= " -- Allgemeine Beschreibung: $comment" if $comment;
            $context .= " -- Anweisungen fuer Claude: $claudeInstructions" if $claudeInstructions;
            $context .= " -- Befehle: $cmdsStr\n";
        }
    }

    return $context;
}

##############################################################################
# Helper function: return tool definitions for Claude Tool Use
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
# Helper function: reconstruct a valid Claude chat for tool use
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

##############################################################################
# Helper function: sanitize chat history into a valid Claude API message sequence
##############################################################################
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
# Helper function: reset control session chat (error handling)
##############################################################################
sub Claude_RollbackControlSession {
    my ($hash) = @_;
    return unless $hash && ref($hash) eq 'HASH';

    my $chat = $hash->{CHAT};
    if ($chat && ref($chat) eq 'ARRAY') {
        my $chatCount = scalar(@$chat);
        my $startIdx = $hash->{CONTROL_START_IDX} // 0;

        $startIdx = 0 if !defined $startIdx || $startIdx < 0;
        $startIdx = $chatCount if $startIdx > $chatCount;

        splice(@{$chat}, $startIdx);
    }

    delete $hash->{CONTROL_START_IDX};
    delete $hash->{CONTROL_SUCCESSFUL_DEVICES};
    delete $hash->{CONTROL_SUCCESSFUL_COMMANDS};
    delete $hash->{CHAT_EXTRA_CONTEXT};
}

##############################################################################
# Helper function: build context from the last successfully controlled devices
##############################################################################
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

##############################################################################
# Helper function: build referential batch context for follow-up instructions
##############################################################################
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

##############################################################################
# Helper function: compose the control-specific system prompt
##############################################################################
sub Claude_BuildControlSystemPrompt {
    my ($hash, %opts) = @_;

    my $includeControlContext = exists $opts{include_control_context} ? $opts{include_control_context} : 1;
    my $name = $hash->{NAME};

    my $systemPrompt            = AttrVal($name, 'systemPrompt', '');
    my $extraContext            = $hash->{CHAT_EXTRA_CONTEXT} // '';
    my $controlContext          = $includeControlContext ? Claude_BuildControlContext($hash) : '';
    my $lastControlledContext   = Claude_BuildLastControlledContext($hash);
    my $lastControlBatchContext = Claude_BuildLastControlBatchContext($hash);

    my @systemParts;
    push @systemParts, $systemPrompt if $systemPrompt ne '';
    push @systemParts, "Steuerregeln:\n- Verweise wie sie/die/diese/wieder/nochmal bevorzugt auf die letzte gemeinsame Zielmenge beziehen.\n- Niemals Tool-Aufrufe mit leerem device oder command erzeugen.\n- Bei Unklarheit bevorzugt die letzte gemeinsame Zielmenge statt nur eines Einzelgeraets nutzen.\n- Wenn weiter unklar, nur eindeutig bestimmbare Geraete verwenden.\n- Nach Erfolg genau 1 kurzen Satz antworten.\n- Keine Geraetelisten ausgeben, ausser bei explizitem Wunsch.\n- Bevorzuge kurze Sammelformulierungen wie 'Die Wohnzimmerbeleuchtung ist jetzt aus.'";
    push @systemParts, $extraContext if $extraContext ne '';
    push @systemParts, $lastControlBatchContext if $lastControlBatchContext ne '';
    push @systemParts, $lastControlledContext if $lastControlledContext ne '';
    push @systemParts, $controlContext if $controlContext ne '';

    return join("\n\n", @systemParts);
}

##############################################################################
# Helper function: normalize natural language text for matching/comparison
##############################################################################
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

##############################################################################
# Helper function: infer device traits from commands, readings and metadata
##############################################################################
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

##############################################################################
# Helper function: derive searchable category tokens for a device
##############################################################################
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

##############################################################################
# Helper function: extract normalized intent signals from an instruction
##############################################################################
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
    $signals{percent_value}     = 1 if $text =~ /%|\b(?:prozent|pct)\b/;
    $signals{temperature_value} = 1 if $text =~ /\b(?:grad|temperature|temperatur|desired temp|desiredtemp|solltemperatur)\b/;
    $signals{numeric_value}     = 1 if $text =~ /\b-?\d+(?:[.,]\d+)?\b/;

    return \%signals;
}

##############################################################################
# Helper function: decide whether a chat message should use control mode
##############################################################################
sub Claude_ChatLooksLikeControlIntent {
    my ($hash, $message) = @_;
    return 0 unless defined $message && $message ne '';

    my $signals = Claude_GetIntentSignals($message);
    return 1 if $signals->{turn_on} || $signals->{turn_off} || $signals->{toggle} || $signals->{increase} || $signals->{decrease} || $signals->{open_like} || $signals->{close_like} || $signals->{stop};

    return 1 if Claude_IsReferentialFollowupInstruction($message, $hash);

    my $text = Claude_NormalizeText($message);
    return 0 if $text eq '';

    return 1 if $signals->{numeric_value} && $text =~ /\b(?:stell|setze|setz|dimme|dimm|fahre|position|prozent|grad)\b/;

    return 0;
}

##############################################################################
# Helper function: define command families used by local command inference
##############################################################################
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

##############################################################################
# Helper function: map an instruction to likely command families
##############################################################################
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

##############################################################################
# Helper function: match a device category/type token in an instruction
##############################################################################
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

##############################################################################
# Helper function: collect candidate set commands for an instruction
##############################################################################
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

##############################################################################
# Helper function: choose a command supported by all candidate devices
##############################################################################
sub Claude_ResolveCommandFromCandidates {
    my ($devices, $candidates) = @_;
    return '' unless $devices && ref($devices) eq 'ARRAY' && @$devices;
    return '' unless $candidates && ref($candidates) eq 'ARRAY' && @$candidates;

    for my $candidate (@$candidates) {
        return $candidate if Claude_AllDevicesSupportCommand($devices, $candidate);
    }

    return '';
}

##############################################################################
# Helper function: choose a value command valid for all candidate devices
##############################################################################
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

##############################################################################
# Helper function: match a room token referenced in an instruction
##############################################################################
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

##############################################################################
# Helper function: decide whether a room label is suitable for summaries
##############################################################################
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

##############################################################################
# Helper function: infer a shared room label from a device list
##############################################################################
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

##############################################################################
# Helper function: convert a room label to simple title case for output
##############################################################################
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

##############################################################################
# Helper function: resolve the remembered room label from the last batch
##############################################################################
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

##############################################################################
# Helper function: decide whether remembered batch room context should win
##############################################################################
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

    return 0 if $rememberedNorm eq '';
    return 1 if $currentNorm eq '';

    return ($currentNorm ne $rememberedNorm) ? 1 : 0;
}

##############################################################################
# Helper function: parse and normalize the available set commands of a device
##############################################################################
sub Claude_SplitTopLevelWhitespace {
    my ($text) = @_;
    return () unless defined $text && $text ne '';

    my @entries;
    my $buffer = '';
    my $in_single = 0;
    my $in_double = 0;
    my $brace_depth = 0;
    my $paren_depth = 0;
    my $bracket_depth = 0;
    my $escaped = 0;

    for my $char (split(//, $text)) {
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
    return @entries;
}

##############################################################################
# Helper function: extract a normalized command name from a set-list entry
##############################################################################
sub Claude_ParseSetListEntry {
    my ($entry) = @_;
    return ('', '') unless defined $entry;

    $entry =~ s/^\s+|\s+$//g;
    return ('', '') if $entry eq '';
    return ('', '') if $entry =~ /^\?/;

    my ($cmdName, $spec) = split(/:/, $entry, 2);
    return ('', '') unless defined $cmdName;

    $cmdName =~ s/^\s+|\s+$//g;
    return ('', '') if $cmdName eq '';
    return ('', '') if $cmdName =~ /\s/;
    return ('', '') unless $cmdName =~ /^[A-Za-z0-9_.#+\-]+$/;

    $spec = '' unless defined $spec;
    $spec =~ s/^\s+|\s+$//g;

    return ($cmdName, $spec);
}

##############################################################################
# Helper function: parse and normalize the available set commands of a device
##############################################################################
sub Claude_ExtractSetListEntries {
    my ($raw) = @_;
    return () unless defined $raw && $raw ne '';

    my $setListRaw = $raw;
    $setListRaw =~ s/\r\n/\n/g;
    $setListRaw =~ s/\r/\n/g;
    $setListRaw =~ s/\t/ /g;
    $setListRaw =~ s/^\s+|\s+$//g;
    return () if $setListRaw eq '';

    my @entries;
    my %seen;

    for my $entry (Claude_SplitTopLevelWhitespace($setListRaw)) {
        next unless defined $entry && $entry ne '';
        next if $seen{$entry}++;
        push @entries, $entry;
    }

    for my $line (split(/\n/, $setListRaw)) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';

        while ($line =~ /(?:^|\s)([A-Za-z0-9_.#+\-]+)(?::((?:[^{}\[\]()"'\s]+|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\})*))?/g) {
            my $cmdName = $1;
            my $spec = defined $2 ? $2 : '';
            my $entry = $cmdName . ($spec ne '' ? ":$spec" : '');
            next if $seen{$entry}++;
            push @entries, $entry;
        }
    }

    return @entries;
}

##############################################################################
# Helper function: parse and normalize the available set commands of a device
##############################################################################
sub Claude_GetDeviceCommandMap {
    my ($devName) = @_;
    my %commands;
    return \%commands unless defined $devName && $devName ne '' && exists $main::defs{$devName};

    my @rawSources = (
        main::getAllSets($devName),
        AttrVal($devName, 'setList', ''),
        AttrVal($devName, 'setExtensions', '')
    );

    for my $raw (@rawSources) {
        next unless defined $raw && $raw ne '';

        for my $entry (Claude_ExtractSetListEntries($raw)) {
            my ($cmdName, $spec) = Claude_ParseSetListEntry($entry);
            next unless $cmdName ne '';
            $commands{$cmdName} = $spec unless exists $commands{$cmdName};
        }
    }

    return \%commands;
}

##############################################################################
# Helper function: check whether a device supports a specific set command
##############################################################################
sub Claude_DeviceSupportsCommand {
    my ($devName, $command) = @_;
    return 0 unless defined $devName && defined $command && $command ne '';

    my $commandMap = Claude_GetDeviceCommandMap($devName);
    return exists $commandMap->{$command} ? 1 : 0;
}

##############################################################################
# Helper function: check whether all devices support a specific command
##############################################################################
sub Claude_AllDevicesSupportCommand {
    my ($devices, $command) = @_;
    return 0 unless $devices && ref($devices) eq 'ARRAY' && @$devices;
    return 0 unless defined $command && $command ne '';

    for my $devName (@$devices) {
        return 0 unless Claude_DeviceSupportsCommand($devName, $command);
    }

    return 1;
}

##############################################################################
# Helper function: normalize set-list values for comparisons
##############################################################################
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

##############################################################################
# Helper function: validate a value against the command spec of a device
##############################################################################
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

    if ($spec =~ /^(?:textField(?:-long)?|colorpicker|color|time|date|datetime|multiple(?:-strict)?|reading|knob|noArg)$/i) {
        return 1;
    }

    if ($spec =~ /^([^,]+(?:,[^,]+)*)$/) {
        my %allowed = map { Claude_NormalizeSetSpecValue($_) => 1 } split(/,/, $spec);
        return exists $allowed{$normalizedValue} ? 1 : 0;
    }

    return 1;
}

##############################################################################
# Helper function: reject instructions that are too complex for local execution
##############################################################################
sub Claude_IsLocalInstructionStructurallySafe {
    my ($instruction) = @_;
    return 0 unless defined $instruction;

    my $rawText = lc($instruction);
    $rawText =~ s/[.!]+/ /g;
    $rawText =~ s/\b(?:bitte|mal)\b//g;
    $rawText =~ s/\s+/ /g;
    $rawText =~ s/^\s+|\s+$//g;

    return 0 if $rawText =~ /[,;:]/;
    return 0 if $rawText =~ /\b(?:aber|jedoch|sondern|statt|ausser|sowie|waehrend|wahrend|bis auf|mit ausnahme|erst|zuerst|anschliessend|anschliesend|danach|dann|nur|lediglich|ausschliesslich|nicht|kein|keine|keinen|keinem|keiner|keines|keins|ohne|wenn|falls|sonst|spaeter|spater|nachher|vorher|gleichzeitig)\b/;

    my $text = Claude_NormalizeText($instruction);
    $text =~ s/\b(?:bitte|mal)\b/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    return 0 if $text eq '';

    return 0 if $text =~ /\b(?:haelfte|halb|teil|ein paar|paar|mehrere|wenige|einige|alle ausser|bis auf|ausser)\b/;
    return 0 if $text =~ /\b(?:und|oder)\b/;
    return 0 if $text =~ /\b(?:prozent)\b/ && $text !~ /\b-?\d+(?:[.,]\d+)?\s*prozent\b/;

    my @actionPositions;
    while ($text =~ /\b(?:schalte|schalt|mache|mach|lass|lasse|schalten|einschalten|ausschalten|anmachen|ausmachen|umschalten|dimme|dimmen|oeffne|oeffnen|schliesse|schliessen|fahre|stoppe|stelle|setz|setze|erhoehe|verringere|senke)\b/g) {
        push @actionPositions, pos($text);
        return 0 if @actionPositions > 1;
    }

    return 1;
}

##############################################################################
# Helper function: classify an instruction for local resolver handling
##############################################################################
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
            Log3 $name, 4, "Claude ($name): LocalResolver discarded referential follow-up because of a concrete target aliasMatches=[" . join(', ', @aliasMatches) . "] room='$room' type='$type'";
        }
    }

    return 'value_assignment' if $signals->{numeric_value};
    return 'device_command' if $signals->{turn_on} || $signals->{turn_off} || $signals->{toggle} || $signals->{increase} || $signals->{decrease} || $signals->{open_like} || $signals->{close_like} || $signals->{stop};

    return 'unsupported';
}

##############################################################################
# Helper function: infer a value-based command and value from text
##############################################################################
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

##############################################################################
# Helper function: infer a plain device command from text
##############################################################################
sub Claude_InferDeviceCommand {
    my ($instruction, $devices) = @_;
    return ('', '') unless defined $instruction;

    my @candidates = Claude_GetCandidateCommandsForInstruction($instruction, $devices);
    my $command = Claude_ResolveCommandFromCandidates($devices, \@candidates);

    return ($command, '') if $command ne '';
    return ('', '');
}

##############################################################################
# Helper function: match concrete devices by alias/name tokens
##############################################################################
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

##############################################################################
# Helper function: central wrapper for local command inference
##############################################################################
sub Claude_InferLocalCommand {
    my ($instruction, $devices) = @_;
    return Claude_InferDeviceCommand($instruction, $devices);
}

##############################################################################
# Helper function: normalize category/type aliases to canonical tokens
##############################################################################
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

##############################################################################
# Helper function: test whether a device matches a normalized type token
##############################################################################
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

##############################################################################
# Helper function: build a human-friendly group label from device traits
##############################################################################
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

##############################################################################
# Helper function: build a deterministic variant index for local summaries
##############################################################################
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

##############################################################################
# Helper function: choose a weighted wording variant for local summaries
##############################################################################
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

##############################################################################
# Helper function: choose a temporal adverb for local summaries
##############################################################################
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

##############################################################################
# Helper function: choose a repeat phrase for follow-up summaries
##############################################################################
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

##############################################################################
# Helper function: choose a verb for value-setting summaries
##############################################################################
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

##############################################################################
# Helper function: choose a generic completion verb for summaries
##############################################################################
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

##############################################################################
# Helper function: choose a motion verb for cover movement summaries
##############################################################################
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

##############################################################################
# Helper function: choose a movement direction phrase for summaries
##############################################################################
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

##############################################################################
# Helper function: infer a display unit for local summary values
##############################################################################
sub Claude_LocalSummaryValueUnit {
    my ($command) = @_;
    return '%'    if defined $command && $command =~ /^(?:pct|bri|brightness|position)\b/;
    return 'Grad' if defined $command && $command =~ /^(?:desired-temp|temperature|desiredTemperature|temp)\b/;
    return '';
}

##############################################################################
# Helper function: build a natural-language value phrase for summaries
##############################################################################
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

##############################################################################
# Helper function: build the final local control response sentence
##############################################################################
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
    return "$subject sind$temporal$repeat an." if $command eq 'on' && !$takes_singular && $hasRepeatCue;
    return "$subject ist$temporal an." if $command eq 'on' && $takes_singular;
    return "$subject sind$temporal an." if $command eq 'on';
    return "$subject ist$temporal$repeat aus." if $command eq 'off' && $takes_singular && $hasRepeatCue;
    return "$subject sind$temporal$repeat aus." if $command eq 'off' && !$takes_singular && $hasRepeatCue;
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

##############################################################################
# Helper function: execute a locally resolved batch command
##############################################################################
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
    my $plain = Claude_MarkdownToPlain($summary);
    my $html  = Claude_MarkdownToHTML($summary);
    my $ssml  = Claude_MarkdownToSSML($summary);

    my $showAdvancedTokenReadings = Claude_HasAdvancedTokenReadingsEnabled($hash);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastCommand',       $lastCmd);
    readingsBulkUpdate($hash, 'lastCommandResult', 'ok');
    readingsBulkUpdate($hash, 'response',          $summary);
    readingsBulkUpdate($hash, 'responsePlain',     $plain);
    readingsBulkUpdate($hash, 'responseHTML',      $html);
    readingsBulkUpdate($hash, 'responseSSML',      $ssml);
    readingsBulkUpdate($hash, 'state',             'ok');
    readingsBulkUpdate($hash, 'lastError',         '-');
    if ($showAdvancedTokenReadings) {
        readingsBulkUpdate($hash, 'lastRequestModel',         AttrVal($name, 'model', 'claude-haiku-4-5'));
        readingsBulkUpdate($hash, 'lastRequestType',          'control');
        readingsBulkUpdate($hash, 'lastRequestWasLocal',      '1');
        readingsBulkUpdate($hash, 'lastApiCallUsedTools',     '0');
        readingsBulkUpdate($hash, 'toolUseCount',             '0');
        readingsBulkUpdate($hash, 'toolSetDeviceCount',       '0');
        readingsBulkUpdate($hash, 'toolGetDeviceStateCount',  '0');
        readingsBulkUpdate($hash, 'stopReason',               'local');
        readingsBulkUpdate($hash, 'stopSequence',             '-');
        readingsBulkUpdate($hash, 'stopDetails',              '-');
        readingsBulkUpdate($hash, 'responseId',               '-');
        readingsBulkUpdate($hash, 'responseType',             'local');
        readingsBulkUpdate($hash, 'responseRole',             'assistant');
        readingsBulkUpdate($hash, 'serviceTier',              '-');
        readingsBulkUpdate($hash, 'inferenceGeo',             '-');
        readingsBulkUpdate($hash, 'cacheCreationInputTokens', '-');
        readingsBulkUpdate($hash, 'cacheReadInputTokens',     '-');
        readingsBulkUpdate($hash, 'cacheCreationEphemeral5mInputTokens', '-');
        readingsBulkUpdate($hash, 'cacheCreationEphemeral1hInputTokens', '-');
    }
    readingsEndUpdate($hash, 1);

    if (!$showAdvancedTokenReadings) {
        Claude_ClearAdvancedTokenReadings($hash);
    }

    Log3 $name, 4, "Claude ($name): Local quick resolution executed: command=$command devices=" . join(', ', @successfulDevices);
    return 1;
}

##############################################################################
# Main helper: try to execute a control instruction without an API round-trip
##############################################################################
sub Claude_ShouldAllowLocalResolution {
    my ($instruction, $matchedDevices) = @_;
    return 0 unless defined $instruction && $instruction ne '';
    return 0 unless Claude_IsLocalInstructionStructurallySafe($instruction);

    my $text = Claude_NormalizeText($instruction);
    return 0 if $text eq '';

    my $signals = Claude_GetIntentSignals($instruction);
    return 0 if (!$signals->{numeric_value} && $text =~ /\b(?:auf|um)\b/ && $text =~ /\b(?:uhr|morgen|abend|nacht)\b/);

    return 0 if $text =~ /\b(?:nicht|kein|keine|keinen|keinem|keiner|keines|ohne|ausser|bis auf)\b/;
    return 0 if $text =~ /\b(?:oder|entweder|weder)\b/;
    return 0 if $text =~ /\b(?:alle|gesamt|saemtliche|sämtliche)\b/ && $text =~ /\b(?:bis auf|ausser|ohne)\b/;

    if ($matchedDevices && ref($matchedDevices) eq 'ARRAY' && @$matchedDevices) {
        my $room = Claude_MatchRoomToken($instruction, $matchedDevices);
        my $type = Claude_MatchDeviceType($instruction, $matchedDevices);
        my @aliasMatches = Claude_MatchDevicesByAlias($instruction, $matchedDevices);

        return 0 if @aliasMatches > 1 && ($room ne '' || $type ne '');
    }

    return 1;
}

##############################################################################
# Main helper: try to execute a control instruction without an API round-trip
##############################################################################
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

    unless (Claude_ShouldAllowLocalResolution($instruction, \@matched)) {
        Log3 $name, 4, "$logPrefix abort: structural safety veto after target resolution";
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

##############################################################################
# Helper function: store the last successfully controlled devices
##############################################################################
sub Claude_RememberControlledDevices {
    my ($hash, $devices) = @_;
    return unless $devices && ref($devices) eq 'ARRAY';

    my %seen;
    my @unique = grep { defined $_ && $_ ne '' && !$seen{$_}++ } @$devices;
    $hash->{LAST_CONTROLLED_DEVICES} = \@unique;
}

##############################################################################
# Helper function: persist the last successful control batch for follow-ups
##############################################################################
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

##############################################################################
# Helper function: detect repeat wording in a follow-up instruction
##############################################################################
sub Claude_HasRepeatCue {
    my ($instruction) = @_;
    return 0 unless defined $instruction;

    my $text = Claude_NormalizeText($instruction);
    return 0 if $text eq '';

    return ($text =~ /\b(?:wieder|nochmal|erneut)\b/) ? 1 : 0;
}

##############################################################################
# Helper function: detect referential follow-up instructions
##############################################################################
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

    my $batch = ($hash && ref($hash) eq 'HASH') ? $hash->{LAST_CONTROL_BATCH} : undef;
    $batch = undef unless $batch && ref($batch) eq 'HASH';
    return 0 unless $batch && $batch->{devices} && ref($batch->{devices}) eq 'ARRAY' && @{$batch->{devices}};

    return 1;
}

##############################################################################
# Helper function: expand follow-up instructions with remembered target context
##############################################################################
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

##############################################################################
# Helper function: infer a batch command for remembered target sets
##############################################################################
sub Claude_InferReferentialBatchCommand {
    my ($instruction, $devices) = @_;
    return ('', '') unless defined $instruction;
    return ('', '') unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my ($valueCommand, $value) = Claude_InferValueCommand($instruction, $devices);
    return ($valueCommand, $value) if defined $valueCommand && $valueCommand ne '';

    my @candidates = Claude_GetCandidateCommandsForInstruction($instruction, $devices);
    my $command = Claude_ResolveCommandFromCandidates($devices, \@candidates);

    return ($command, '') if defined $command && $command ne '';
    return ('', '');
}

##############################################################################
# Helper function: finalize remembered devices/commands after a control session
##############################################################################
sub Claude_FinalizeRememberedControlSession {
    my ($hash) = @_;

    my $devices  = delete $hash->{CONTROL_SUCCESSFUL_DEVICES};
    my $commands = delete $hash->{CONTROL_SUCCESSFUL_COMMANDS};
    my $instruction = $hash->{LAST_CONTROL_INSTRUCTION};

    return unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    Claude_RememberControlledDevices($hash, $devices);
    Claude_RememberControlBatch($hash, $instruction, $devices, $commands);

    my $name = $hash->{NAME};
    Log3 $name, 4, "Claude ($name): Finalizing control session for last target set: " . join(', ', @$devices);
}

##############################################################################
# Helper function: execute referential follow-up instructions locally
##############################################################################
sub Claude_ExecuteReferentialBatchLocally {
    my ($hash, $instruction) = @_;
    return 0 unless Claude_IsReferentialFollowupInstruction($instruction, $hash);

    my $batch = $hash->{LAST_CONTROL_BATCH};
    return 0 unless $batch && ref($batch) eq 'HASH';

    my %previousBatch = %{$batch};

    my $devices = $batch->{devices};
    return 0 unless $devices && ref($devices) eq 'ARRAY' && @$devices;

    my ($command, $value) = Claude_InferReferentialBatchCommand($instruction, $devices);
    return 0 unless defined $command && $command ne '';

    my $name = $hash->{NAME};
    my @successfulDevices;
    my @successfulCommands;
    my @executedLines;
    my $setSuffix = defined $value && $value ne '' ? "$command $value" : $command;

    my %allowed = map { $_ => 1 } Claude_GetControlDevices($hash);

    for my $device (@$devices) {
        next unless defined $device && $device ne '';
        next unless $allowed{$device};
        next unless exists $main::defs{$device};

        if (defined $value && $value ne '') {
            next unless Claude_DeviceSupportsValueForCommand($device, $command, $value);
        } else {
            next unless Claude_DeviceSupportsCommand($device, $command);
        }

        my $setResult = CommandSet(undef, "$device $setSuffix");
        $setResult //= 'ok';
        $setResult = 'ok' if $setResult eq '';

        Log3 $name, 3, "Claude ($name): local referential batch set $device $setSuffix -> $setResult";

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

    my $summary = Claude_BuildLocalControlSummary(
        $instruction,
        $setSuffix,
        \@successfulDevices,
        $hash,
        reference_batch => \%previousBatch
    );

    my $plain = Claude_MarkdownToPlain($summary);
    my $html  = Claude_MarkdownToHTML($summary);
    my $ssml  = Claude_MarkdownToSSML($summary);

    my $showAdvancedTokenReadings = Claude_HasAdvancedTokenReadingsEnabled($hash);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastCommand',       $lastCmd);
    readingsBulkUpdate($hash, 'lastCommandResult', 'ok');
    readingsBulkUpdate($hash, 'response',          $summary);
    readingsBulkUpdate($hash, 'responsePlain',     $plain);
    readingsBulkUpdate($hash, 'responseHTML',      $html);
    readingsBulkUpdate($hash, 'responseSSML',      $ssml);
    readingsBulkUpdate($hash, 'state',             'ok');
    readingsBulkUpdate($hash, 'lastError',         '-');
    if ($showAdvancedTokenReadings) {
        readingsBulkUpdate($hash, 'lastRequestModel',         AttrVal($name, 'model', 'claude-haiku-4-5'));
        readingsBulkUpdate($hash, 'lastRequestType',          'control');
        readingsBulkUpdate($hash, 'lastRequestWasLocal',      '1');
        readingsBulkUpdate($hash, 'lastApiCallUsedTools',     '0');
        readingsBulkUpdate($hash, 'toolUseCount',             '0');
        readingsBulkUpdate($hash, 'toolSetDeviceCount',       '0');
        readingsBulkUpdate($hash, 'toolGetDeviceStateCount',  '0');
        readingsBulkUpdate($hash, 'stopReason',               'local');
        readingsBulkUpdate($hash, 'stopSequence',             '-');
        readingsBulkUpdate($hash, 'stopDetails',              '-');
        readingsBulkUpdate($hash, 'responseId',               '-');
        readingsBulkUpdate($hash, 'responseType',             'local');
        readingsBulkUpdate($hash, 'responseRole',             'assistant');
        readingsBulkUpdate($hash, 'serviceTier',              '-');
        readingsBulkUpdate($hash, 'inferenceGeo',             '-');
        readingsBulkUpdate($hash, 'cacheCreationInputTokens', '-');
        readingsBulkUpdate($hash, 'cacheReadInputTokens',     '-');
        readingsBulkUpdate($hash, 'cacheCreationEphemeral5mInputTokens', '-');
        readingsBulkUpdate($hash, 'cacheCreationEphemeral1hInputTokens', '-');
    }
    readingsEndUpdate($hash, 1);

    if (!$showAdvancedTokenReadings) {
        Claude_ClearAdvancedTokenReadings($hash);
    }

    Log3 $name, 4, "Claude ($name): Referential follow-up instruction resolved locally to batch: command=$setSuffix devices=" . join(', ', @successfulDevices);
    return 1;
}

##############################################################################
# Control function: control device via Claude Tool Use
##############################################################################
sub Claude_SendControl {
    my ($hash, $instruction, $extraContext) = @_;
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
        readingsSingleUpdate($hash, 'lastError', 'No API key set (attr apiKey)', 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): No API key configured!";
        return;
    }

    my $model      = AttrVal($name, 'model',      'claude-haiku-4-5');
    my $timeout    = AttrVal($name, 'timeout',    30);
    my $maxHistory = int(AttrVal($name, 'maxHistory', 10));
    my $effectiveHistory = $maxHistory < 6 ? 6 : $maxHistory;
    my $maxTokens  = int(AttrVal($name, 'maxTokens',  300));
    my $cacheControl = Claude_GetPromptCacheControl($hash);
    my $showAdvancedTokenReadings = Claude_HasAdvancedTokenReadingsEnabled($hash);

    if ($showAdvancedTokenReadings) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, 'lastRequestType',      'control');
        readingsBulkUpdate($hash, 'lastRequestModel',     $model);
        readingsBulkUpdate($hash, 'lastRequestWasLocal',  '0');
        readingsBulkUpdate($hash, 'lastApiCallUsedTools', '1');
        readingsBulkUpdate($hash, 'toolUseCount',         '0');
        readingsBulkUpdate($hash, 'toolSetDeviceCount',   '0');
        readingsBulkUpdate($hash, 'toolGetDeviceStateCount', '0');
        readingsEndUpdate($hash, 1);
    } else {
        Claude_ClearAdvancedTokenReadings($hash);
    }

    Log3 $name, 4, "Claude ($name): Using model $model";

    # Remember the start index so the entire control session
    # can be cleanly removed from history on errors
    $hash->{CONTROL_START_IDX} = scalar(@{$hash->{CHAT}});
    $hash->{CONTROL_SUCCESSFUL_DEVICES}  = [];
    $hash->{CONTROL_SUCCESSFUL_COMMANDS} = [];
    $instruction = Claude_ExpandReferentialInstruction($hash, $instruction);
    Log3 $name, 4, "Claude ($name): Expanded follow-up instruction from '$originalInstruction' to '$instruction'" if $instruction ne $originalInstruction;

    $hash->{LAST_CONTROL_INSTRUCTION} = $originalInstruction;

    $hash->{CHAT_EXTRA_CONTEXT} = $extraContext // '';

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
        my $errMsg = 'Internal error: no valid messages generated for control request';
        readingsSingleUpdate($hash, 'lastError', $errMsg, 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): $errMsg; CHAT=" . Claude_DebugMessageSummary($hash->{CHAT});
        Claude_RollbackControlSession($hash);
        return;
    }
    Log3 $name, 4, "Claude ($name): Control messages " . Claude_DebugMessageSummary($messagesToSend);

    my $fullSystem = Claude_BuildControlSystemPrompt($hash, include_control_context => 1);
    my $systemBlocks = Claude_BuildSystemBlocks($fullSystem, cache_control => $cacheControl);

    Log3 $name, 4, "Claude ($name): Effective control history=$effectiveHistory" if $effectiveHistory != $maxHistory;

    # Control request to Claude:
    # in addition to the messages, the available tools
    # for set_device and get_device_state are included here
    my %requestBody = (
        model      => $model,
        max_tokens => $maxTokens,
        messages   => $messagesToSend,
        tools      => Claude_GetControlTools()
    );

    $requestBody{system} = $systemBlocks if $systemBlocks;

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON encode error: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Claude_RollbackControlSession($hash);
        return;
    }

    Log3 $name, 4, "Claude ($name): Control request " . $jsonBody;

    readingsSingleUpdate($hash, 'state', 'requesting...', 1);

    HttpUtils_NonblockingGet({
        url      => Claude_ApiUrl(),
        timeout  => $timeout,
        method   => 'POST',
        header   => Claude_RequestHeaders($apiKey, prompt_caching => Claude_HasPromptCachingEnabled($hash)),
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Claude_HandleControlResponse,
    });

    return undef;
}

##############################################################################
# Callback: process response to control request / tool result
##############################################################################
sub Claude_HandleControlResponse {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        readingsSingleUpdate($hash, 'lastError', "HTTP error: $err", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): HTTP error: $err";
        Claude_RollbackControlSession($hash);
        return;
    }

    Log3 $name, 5, "Claude ($name): Raw response: $data";

    my $result = eval { decode_json($data) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON parse error: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): JSON parse error: $@";
        Claude_RollbackControlSession($hash);
        return;
    }

    my $toolUseCount = 0;
    my $toolSetCount = 0;
    my $toolGetCount = 0;
    if (ref($result->{content}) eq 'ARRAY') {
        for my $part (@{$result->{content}}) {
            next unless ref($part) eq 'HASH';
            next unless ($part->{type} // '') eq 'tool_use';
            $toolUseCount++;
            my $toolName = $part->{name} // '';
            $toolSetCount++ if $toolName eq 'set_device';
            $toolGetCount++ if $toolName eq 'get_device_state';
        }
    }

    Claude_UpdateResponseMetadataReadings(
        $hash,
        $result,
        request_type   => ReadingsVal($name, 'lastRequestType', 'control'),
        request_model  => ReadingsVal($name, 'lastRequestModel', AttrVal($name, 'model', 'claude-haiku-4-5')),
        was_local      => 0,
        used_tools     => 1,
        tool_use_count => $toolUseCount,
        tool_set_count => $toolSetCount,
        tool_get_count => $toolGetCount
    );

    if (exists $result->{model}) {
        Log3 $name, 4, "Claude ($name): API reports model " . $result->{model};
    }

    if (exists $result->{error}) {
        my $errType = $result->{error}{type}    // 'unknown_error';
        my $errMsg  = $result->{error}{message} // 'Unknown API error';
        readingsSingleUpdate($hash, 'lastError', "API error ($errType): $errMsg", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): API error ($errType): $errMsg";
        Claude_RollbackControlSession($hash);
        return;
    }

    my $contentBlocks = (ref($result->{content}) eq 'ARRAY') ? $result->{content} : [];
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
        my $input    = (ref($part->{input}) eq 'HASH') ? $part->{input} : {};
        my $inputJson = eval { encode_json($input) };
        $inputJson = '{json_encode_error}' if $@;
        Log3 $name, 4, "Claude ($name): ToolUse received: name=$toolName id=$toolId input=$inputJson";

        if ($toolName eq 'set_device') {
            my $device  = $input->{device}  // '';
            my $command = $input->{command} // '';

            if (!$device) {
                my $errMsg = "Error: tool set_device without device";
                Log3 $name, 2, "Claude ($name): $errMsg";
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => $errMsg
                };
                next;
            }

            if (!$command) {
                my $errMsg = "Error: tool set_device without command";
                Log3 $name, 2, "Claude ($name): $errMsg";
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => $errMsg
                };
                next;
            }

            if ($command =~ /[;|`\$\(\)<>\n]/) {
                my $errMsg = "Error: invalid command '$command' (forbidden characters)";
                Log3 $name, 2, "Claude ($name): $errMsg";
                push @toolResults, {
                    type        => 'tool_result',
                    tool_use_id => $toolId,
                    content     => $errMsg
                };
                next;
            }

            my %allowed = map { $_ => 1 } Claude_GetControlDevices($hash);

            if ($allowed{$device} && exists $main::defs{$device}) {
                my ($toolCommandName) = split(/\s+/, $command, 2);

                if (!defined $toolCommandName || $toolCommandName eq '' || !Claude_DeviceSupportsCommand($device, $toolCommandName)) {
                    my $errMsg = "Error: command '$command' not available for device '$device'";

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
                    my $errMsg = "Error: value '$toolValue' not available for command '$toolCommandName' on device '$device'";

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
                my $errMsg = "Error: device '$device' not in controlList or does not exist";

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
            my %allowed = map { $_ => 1 } Claude_GetControlDevices($hash);

            if (!$device) {
                $stateResult = "Error: tool get_device_state without device";
            } elsif (!$allowed{$device} || !exists $main::defs{$device}) {
                $stateResult = "Error: device '$device' not in controlList or does not exist";
            } else {
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
                content     => "Error: unknown tool '$toolName'"
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

            Log3 $name, 4, "Claude ($name): Collecting successful devices for the current control session: " . join(', ', @$sessionDevices);
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
        readingsSingleUpdate($hash, 'lastError', "Empty response, stop_reason: $stopReason", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 2, "Claude ($name): Empty control response, stop_reason: $stopReason";
        Claude_RollbackControlSession($hash);
        return;
    }

    push @{$hash->{CHAT}}, {
        role    => 'assistant',
        content => $contentBlocks
    };

    Claude_FinalizeRememberedControlSession($hash);
    delete $hash->{CONTROL_START_IDX};
    delete $hash->{CHAT_EXTRA_CONTEXT};
    Claude_TrimHistory($hash, (int(AttrVal($name, 'maxHistory', 10)) < 6 ? 6 : int(AttrVal($name, 'maxHistory', 10))));

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

    Log3 $name, 4, "Claude ($name): Control response received (" . length($responseUnicode) . " characters)";
    return undef;
}

##############################################################################
# Helper function: send tool results back to Claude collectively
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
    my $cacheControl = Claude_GetPromptCacheControl($hash);

    Log3 $name, 4, "Claude ($name): Using model $model";

    my $disableHistory = AttrVal($name, 'disableHistory', 0);
    my $messagesToSend;
    if ($disableHistory) {
        my $chat = $hash->{CHAT};
        my $chatCount = ($chat && ref($chat) eq 'ARRAY') ? scalar(@$chat) : 0;
        my $startIdx = $hash->{CONTROL_START_IDX};

        if (!$chatCount) {
            $messagesToSend = [];
        } else {
            $startIdx = 0 unless defined $startIdx;
            $startIdx = 0 if $startIdx < 0;
            $startIdx = $chatCount if $startIdx > $chatCount;

            my @slice = $startIdx < $chatCount ? @{$chat}[$startIdx .. $chatCount - 1] : ();
            $messagesToSend = Claude_SanitizeMessagesForApi(\@slice, $name);
        }
    } else {
        $messagesToSend = Claude_SanitizeMessagesForApi($hash->{CHAT}, $name);
    }

    if (!$messagesToSend || ref($messagesToSend) ne 'ARRAY' || !@$messagesToSend) {
        my $errMsg = 'Internal error: no valid messages generated for tool results';
        readingsSingleUpdate($hash, 'lastError', $errMsg, 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Log3 $name, 1, "Claude ($name): $errMsg; CHAT=" . Claude_DebugMessageSummary($hash->{CHAT});
        Claude_RollbackControlSession($hash);
        return;
    }
    Log3 $name, 4, "Claude ($name): ToolResult messages " . Claude_DebugMessageSummary($messagesToSend);

    my $fullSystem = Claude_BuildControlSystemPrompt($hash, include_control_context => 0);
    my $systemBlocks = Claude_BuildSystemBlocks($fullSystem, cache_control => $cacheControl);

    my %requestBody = (
        model      => $model,
        max_tokens => $maxTokens,
        messages   => $messagesToSend,
        tools      => Claude_GetControlTools()
    );

    $requestBody{system} = $systemBlocks if $systemBlocks;

    my $jsonBody = eval { encode_json(\%requestBody) };
    if ($@) {
        readingsSingleUpdate($hash, 'lastError', "JSON encode error: $@", 1);
        readingsSingleUpdate($hash, 'state', 'error', 1);
        Claude_RollbackControlSession($hash);
        return;
    }

    my @toolIds = map { $_->{tool_use_id} // '?' } @$toolResults;
    my @toolContents = map { ($_->{tool_use_id} // '?') . '=' . ($_->{content} // '') } @$toolResults;
    Log3 $name, 4, "Claude ($name): ToolResults sent for '" . join("', '", @toolIds) . "'";
    Log3 $name, 4, "Claude ($name): ToolResult contents: " . join(' || ', @toolContents);
    Log3 $name, 4, "Claude ($name): ToolResult Request " . $jsonBody;

    HttpUtils_NonblockingGet({
        url      => Claude_ApiUrl(),
        timeout  => $timeout,
        method   => 'POST',
        header   => Claude_RequestHeaders($apiKey, prompt_caching => Claude_HasPromptCachingEnabled($hash)),
        data     => $jsonBody,
        hash     => $hash,
        callback => \&Claude_HandleControlResponse,
    });

    return undef;
}

1;

=pod
=item summary    Anthropic Claude AI assistant
=item summary_DE Anthropic Claude KI Assistent

=begin html

<a id="Claude"></a>
<h3>Claude</h3>
<ul>
  Intelligent smart home control assistant powered by Anthropic Claude AI.
  <br><br>

  Project documentation, examples, and current notes:
  <a href="https://github.com/TheRealWolfpunk/FHEM-Claude" target="_blank">GitHub project page &quot;FHEM-Claude&quot;</a>
</ul>

=end html

=begin html_DE

<a id="Claude"></a>
<h3>Claude</h3>
<ul>
  Intelligente Smarthome Kontrolle mit Hilfe des Anthropic Claude KI Assistenten.
  <br><br>

  Projektdokumentation, Beispiele und aktuelle Hinweise:
  <a href="https://github.com/TheRealWolfpunk/FHEM-Claude" target="_blank">GitHub Projektseite &quot;FHEM-Claude&quot;</a>
</ul>

=end html_DE

=begin html

<a id="Claude-define"></a>
<b>Define</b>
<ul>
  <code>define &lt;name&gt; Claude</code>
  <br><br>
  Creates the Claude AI assistant device in FHEM.
</ul><br>

=end html

=begin html_DE

<a id="Claude-define"></a>
<b>Define</b>
<ul>
  <code>define &lt;name&gt; Claude</code>
  <br><br>
  Legt den Claude KI Assistenten in FHEM an.
</ul><br>

=end html_DE

=begin html

<a id="Claude-set"></a>
<b>Set</b>
<ul>
  <li>ask &lt;question&gt;<br>
    Asks the assistant a text question.</li><br>

  <li>askWithImage &lt;imagePath&gt; &lt;question&gt;<br>
    Sends an image together with a question to the assistant.</li><br>

  <li>askAboutDevices [&lt;question&gt;]<br>
    Asks the assistant device-specific questions.</li><br>

  <li>chat &lt;message&gt;<br>
    Universal command for general questions, device status, and control in one.<br>
    If controllable devices are configured via controlList and/or controlRoom, the message is processed through the control logic. Otherwise, it is handled as a normal request with optional device context.<br>
    Especially useful for Telegram or notify integrations.</li><br>

  <li>control &lt;instruction&gt;<br>
    Controls FHEM devices via natural-language command.<br>
    By default, the module runs in Claude hybrid mode (local mode): many simple standard commands are executed directly in FHEM, while Claude handles more complex or more freely phrased instructions.
    This allows typical switching actions to work without an additional API call, which can save tokens and therefore costs in everyday use.
    Only devices from controlList and/or rooms included through controlRoom may be controlled.
    Example: set ClaudeAI control Turn on the living room lamp.</li><br>

  <li>resetChat<br>
    Clears the chat history.</li>
</ul><br>

=end html

=begin html_DE

<a id="Claude-set"></a>
<b>Set</b>
<ul>
  <li>ask <Frage><br>
    Stellt eine Textfrage an den Assistenten.</li><br>

  <li>askWithImage &lt;Bildpfad&gt; &lt;Frage&gt;<br>
    Sendet ein Bild und eine Frage dazu an den Assistenten.</li><br>
      
  <li>askAboutDevices [&lt;Frage&gt;]<br>
    Stellt dem Assistenten gerätespezifische Fragen.</li><br>

  <li>chat &lt;Nachricht&gt;<br>
    Universeller Befehl für allgemeine Fragen, Geräte-Status und Steuerung in einem.<br>
    Wenn steuerbare Geräte per controlList und/oder controlRoom konfiguriert sind, wird die Nachricht über die Control-Logik verarbeitet. Andernfalls als normale Anfrage mit optionalem Gerätekontext.<br>
    Besonders praktisch für Telegram- oder Notify-Integrationen.</li><br>

  <li>control &lt;Anweisung&gt;<br>
    Steuert FHEM-Geräte per Sprachbefehl.<br>
    Im Standard arbeitet das Modul im Claude-Hybridbetrieb (Lokalmodus): Viele einfache Standardbefehle werden direkt lokal in FHEM ausgeführt, während Claude komplexere oder freier formulierte Anweisungen übernimmt.
    Dadurch sind typische Schaltvorgänge oft ohne zusätzlichen API-Aufruf möglich, was im Alltag Tokens und damit Kosten sparen kann.
    Gesteuert werden dürfen nur Geräte aus controlList und/oder den über controlRoom einbezogenen Räumen.
    Beispiel: set ClaudeAI control Mach die Wohnzimmerlampe an.</li><br>

  <li>resetChat<br>
    Löscht den Chat-Verlauf.</li>
</ul><br>

=end html_DE

=begin html

<a id="Claude-get"></a>
<b>Get</b>
<ul>
  <li>chatHistory<br>
    Shows the chat history.</li>
</ul><br>

=end html

=begin html_DE

<a id="Claude-get"></a>
<b>Get</b>
<ul>
  <li>chatHistory<br>
    Zeigt den Chat-Verlauf an.</li>
</ul><br>

=end html_DE

=begin html

<a id="Claude-attr"></a>
<b>Attributes</b>
<ul>
  <a id="Claude-attr-apiKey"></a>
  <li>apiKey<br>
    Sets the personal Anthropic API key.<br>
    Without the key, no requests can be sent to Claude.</li><br>

  <a id="Claude-attr-model"></a>
  <li>model<br>
    Claude model to use (default: claude-haiku-4-5).<br>
    claude-haiku-4-5 is currently the most cost-effective available Claude model and a good default choice for many typical FHEM use cases.</li><br>

  <a id="Claude-attr-timeout"></a>
  <li>timeout<br>
    HTTP timeout in seconds (default: 30)</li><br>

  <li><a href="#disable">disable</a><br>
    Disables the module.</li><br>

  <a id="Claude-attr-systemPrompt"></a>
  <li>systemPrompt<br>
    Optional system prompt that is sent with every request.<br>
    The longer the prompt, the larger the context sent with each request becomes.</li><br>

  <a id="Claude-attr-maxHistory"></a>
  <li>maxHistory<br>
    Maximum number of stored chat messages (default: 10).<br>
    A smaller value keeps the transmitted history more compact because fewer previous messages are resent to Claude.</li><br>

  <a id="Claude-attr-maxTokens"></a>
  <li>maxTokens<br>
    Maximum response length.<br>
    If the attribute is not set, the module uses different fallback values depending on the request type:
    600 for normal requests such as ask or askAboutDevices, and 300 for control or Tool Use.
    If the attribute is set, this value overrides the respective fallbacks.
    A smaller value limits expected token usage, but responses may become shorter.</li><br>

  <a id="Claude-attr-disableHistory"></a>
  <li>disableHistory<br>
    Disables chat history.<br>
    When disabled, each request is sent without previous chat history and treated as a standalone conversation.
    The internal history is still kept (for resetChat), but it is not transmitted to the API.
    This can save tokens in many use cases, but reduces conversational context.</li><br>

  <a id="Claude-attr-promptCaching"></a>
  <li>promptCaching<br>
    Enables prompt caching in the Claude API.<br>
    This is especially useful for recurring prompts, device contexts, or similar requests and can reduce ongoing usage.</li><br>

  <a id="Claude-attr-showAdvancedReadings"></a>
  <li>showAdvancedReadings<br>
    Enables advanced technical readings.
    When enabled, additional request, tool-use, response metadata, and token/cache detail readings are shown.
    By default, these details are hidden.</li><br>

  <a id="Claude-attr-deviceContextMode"></a>
  <li>deviceContextMode [compact|detailed]<br>
    Controls how much device information is sent to Claude for askAboutDevices.<br>
    compact sends only the alias, the current status, and up to 3 important readings per device.
    This is already sufficient for many typical summaries and keeps the context small.<br>
    detailed additionally sends the internal device name, the type, and further attributes such as room, group, and alias.
    This is more verbose and can help with more complex follow-up questions.</li><br>

  <a id="Claude-attr-deviceList"></a>
  <li>deviceList<br>
    Comma-separated device list for askAboutDevices</li><br>

  <a id="Claude-attr-deviceRoom"></a>
  <li>deviceRoom<br>
    Comma-separated room list<br>
    All devices with a matching room attribute are automatically used for askAboutDevices.
    Can be used together with deviceList.<br>
    Example: attr ClaudeAI deviceRoom Wohnzimmer,Kueche.</li><br>

  <a id="Claude-attr-controlContextMode"></a>
  <li>controlContextMode [compact|detailed]<br>
    Controls how much information is sent to Claude for the control command.<br>
    compact sends only alias, internal name, and current status per device.
    This is already sufficient for many simple switching commands and keeps the context small.<br>
    detailed additionally sends a compact list of typical available commands.
    This helps Claude with more complex control instructions and can improve the resolution of freer formulations.</li><br>

  <a id="Claude-attr-localControlResolver"></a>
  <li>localControlResolver<br>
    Enables the local resolver for Claude hybrid mode on control commands.<br>
    This feature is enabled by default.<br>
    When enabled, the module works in hybrid mode: many simple and unambiguous control commands are executed directly in FHEM.
    In these cases, no additional Claude API call is required.
    This saves tokens and therefore ongoing costs in everyday use, making Claude in FHEM generally affordable for typical control tasks in practice.<br>
    Complex, ambiguous, or freely phrased instructions continue to run automatically through Claude.
    When disabled, every control command is processed fully through Claude.<br>
    The local resolver is intentionally conservative and only handles commands that can be resolved safely and unambiguously.
    Freer or more ambiguous formulations therefore remain on the Claude fallback path.</li><br>

  <a id="Claude-attr-controlList"></a>
  <li>controlList<br>
    Comma-separated list of devices that Claude may control via Tool Use.<br>
    Can be used together with controlRoom.
    Alias names and available set commands of the devices are automatically transmitted to Claude, so voice commands using aliases and suitable commands can be recognized automatically.
    A compact and sensibly limited list keeps the transmitted context manageable.<br>
    Example: attr ClaudeAI controlList Lampe1,Heizung,Rolladen1</li><br>

  <a id="Claude-attr-controlRoom"></a>
  <li>controlRoom<br>
    Comma-separated room list.<br>
    Devices with a matching room attribute are automatically classified as controllable.
    Can be used together with controlList.<br>
    Example: attr ClaudeAI controlRoom Wohnzimmer,Kueche</li><br>

  <a id="Claude-attr-readingBlacklist"></a>
  <li>readingBlacklist<br>
    Space-separated list of reading or command names that should not be transmitted to Claude.<br>
    Wildcards with * are supported, e.g. R-* or Wifi*.
    The blacklist is applied to device context, control context, and device state queries.</li><br>

  <a id="Claude-attr-.*_Instructions"></a>
  <li>&lt;InstanceName&gt;_Instructions<br>
    Optional attribute on any FHEM device.<br>
    This allows storing device-specific instructions only for this Claude instance.
    The attribute is included in device and control context in addition to the general comment.<br>
    Example: if the name in the define (InstanceName) of the Claude module is &quot;ClaudeAI&quot;, the additional attribute ClaudeAI_Instructions appears on FHEM devices.</li>
</ul><br>

=end html

=begin html_DE

<a id="Claude-attr"></a>
<b>Attributes</b>
<ul>
  <a id="Claude-attr-apiKey"></a>
  <li>apiKey<br>
    Setzt den persönlichen Anthropic API Key.<br>
    Ohne den Key können keine Anfragen an Claude gesendet werden.</li><br>

  <a id="Claude-attr-model"></a>
  <li>model<br>
    Zu verwendendes Claude Modell (Standard: claude-haiku-4-5).<br>
    claude-haiku-4-5 ist aktuell das kostengünstigste verfügbare Claude-Modell und für viele typische FHEM-Anwendungen eine gute Standardwahl.</li><br>

  <a id="Claude-attr-timeout"></a>
  <li>timeout<br>
    HTTP Timeout in Sekunden (Standard: 30)</li><br>

  <li><a href="#disable">disable</a><br>
    Deaktiviert das Modul.</li><br>

  <a id="Claude-attr-systemPrompt"></a>
  <li>systemPrompt<br>
    Optionaler System-Prompt, der bei jeder Anfrage mitgesendet wird.<br>
    Je länger der Prompt ist, desto größer wird der mitgesendete Kontext pro Anfrage.</li><br>

  <a id="Claude-attr-maxHistory"></a>
  <li>maxHistory<br>
    Maximale Anzahl der gespeicherten Chat-Nachrichten (Standard: 10).<br>
    Ein kleinerer Wert hält den mitgesendeten Verlauf kompakter, weil weniger frühere Nachrichten erneut an Claude gesendet werden.</li><br>

  <a id="Claude-attr-maxTokens"></a>
  <li>maxTokens<br>
    Maximale Antwortlänge.<br>
    Wenn das Attribut nicht gesetzt ist, verwendet das Modul je nach Anfrageart unterschiedliche Fallback-Werte:
    600 für normale Anfragen wie ask oder askAboutDevices, sowie 300 für control bzw. Tool Use.
    Wenn das Attribut gesetzt ist, überschreibt dieser Wert die jeweiligen Fallbacks.
    Ein kleinerer Wert begrenzt den zu erwartenden Tokenverbrauch, kann Antworten aber kürzer ausfallen lassen.</li><br>

  <a id="Claude-attr-disableHistory"></a>
  <li>disableHistory<br>
    Deaktiviert den Chat-Verlauf.<br>
    Bei Deaktivierung wird jede Anfrage ohne vorherigen Chat-Verlauf gesendet und als eigenständiges Gespräch behandelt.
    Der interne Verlauf bleibt erhalten (für resetChat), wird aber nicht an die API übermittelt.
    Das kann bei vielen Anwendungsfällen Tokens sparen, reduziert aber den Gesprächskontext.</li><br>

  <a id="Claude-attr-promptCaching"></a>
  <li>promptCaching<br>
    Aktiviert Prompt-Caching in der Claude API.<br>
    Das ist besonders sinnvoll bei wiederkehrenden Prompts, Gerätekontexten oder ähnlichen Anfragen und kann den laufenden Verbrauch reduzieren.</li><br>

  <a id="Claude-attr-showAdvancedReadings"></a>
  <li>showAdvancedReadings<br>
    Aktiviert erweiterte technische Readings.
    Bei Aktivierung werden zusätzliche Request-, Tool-Use-, Response-Metadaten- sowie Token-/Cache-Readings angezeigt.
    In der Standardeinstellung sind diese Details ausgeblendet.</li><br>

  <a id="Claude-attr-deviceContextMode"></a>
  <li>deviceContextMode [compact|detailed]<br>
    Steuert, wie viele Geräteinformationen bei askAboutDevices an Claude gesendet werden.<br>
    compact sendet pro Gerät nur den Alias, den aktuellen Status und bis zu 3 wichtige Readings.
    Das ist für viele typische Zusammenfassungen bereits gut ausreichend und hält den Kontext klein.<br>
    detailed sendet zusätzlich den internen Gerätenamen, den Typ sowie weitere Attribute wie room, group und alias.
    Das ist ausführlicher und kann bei komplexeren Rückfragen hilfreich sein.</li><br>

  <a id="Claude-attr-deviceList"></a>
  <li>deviceList<br>
    Komma-getrennte Geräteliste für askAboutDevices</li><br>

  <a id="Claude-attr-deviceRoom"></a>
  <li>deviceRoom<br>
    Komma-getrennte Raumliste<br>
    Alle Geräte mit passendem room-Attribut werden automatisch für askAboutDevices verwendet.
    Kann zusammen mit deviceList verwendet werden.<br>
    Beispiel: attr ClaudeAI deviceRoom Wohnzimmer,Kueche.</li><br>

  <a id="Claude-attr-controlContextMode"></a>
  <li>controlContextMode [compact|detailed]<br>
    Steuert, wie viele Informationen für den control-Befehl an Claude gesendet werden.<br>
    compact sendet pro Gerät nur Alias, internen Namen und aktuellen Status.
    Das reicht für viele einfache Schaltbefehle bereits gut aus und hält den Kontext klein.<br>
    detailed sendet zusätzlich eine kompakte Liste typischer verfügbarer Befehle mit.
    Das hilft Claude bei komplexeren Steueranweisungen und kann die Auflösung freierer Formulierungen erleichtern.</li><br>

  <a id="Claude-attr-localControlResolver"></a>
  <li>localControlResolver<br>
    Aktiviert den lokalen Resolver für den Claude-Hybridbetrieb bei control-Befehlen.<br>
    In der Standardeinstellung ist diese Funktion aktiviert.<br>
    Bei Aktivierung arbeitet das Modul hybrid: viele einfache und eindeutige Steuerbefehle werden direkt in FHEM ausgeführt.
    Dafür ist in diesen Fällen kein zusätzlicher Claude-API-Aufruf nötig.
    Das spart im Alltag Tokens und damit laufende Kosten, sodass die Nutzung von Claude in FHEM für typische Steueraufgaben in der Praxis meist gut bezahlbar bleibt.<br>
    Komplexe, mehrdeutige oder frei formulierte Anweisungen laufen weiterhin automatisch über Claude.
    Bei Deaktivierung wird jeder control-Befehl vollständig über Claude verarbeitet.<br>
    Der lokale Resolver arbeitet bewusst konservativ und übernimmt nur Befehle, die sicher und eindeutig auflösbar sind.
    Freiere oder mehrdeutige Formulierungen bleiben deshalb beim Claude-Fallback.</li><br>

  <a id="Claude-attr-controlList"></a>
  <li>controlList<br>
    Komma-getrennte Liste der Geräte, die Claude per Tool Use steuern darf.<br>
    Kann zusammen mit controlRoom verwendet werden.
    Alias-Namen und verfügbare set-Befehle der Geräte werden automatisch an Claude übermittelt, sodass Sprachbefehle mit Alias-Namen und passende Befehle automatisch erkannt werden.
    Eine kompakte und sinnvoll begrenzte Liste hält den gesendeten Kontext überschaubar.<br>
    Beispiel: attr ClaudeAI controlList Lampe1,Heizung,Rolladen1</li><br>

  <a id="Claude-attr-controlRoom"></a>
  <li>controlRoom<br>
    Komma-getrennte Raumliste.<br>
    Geräte mit passendem room-Attribut werden automatisch als steuerbar eingestuft.
    Kann zusammen mit controlList verwendet werden.<br>
    Beispiel: attr ClaudeAI controlRoom Wohnzimmer,Kueche</li><br>

  <a id="Claude-attr-readingBlacklist"></a>
  <li>readingBlacklist<br>
    Leerzeichen-getrennte Liste von Reading- oder Befehlsnamen, die nicht an Claude übermittelt werden sollen.<br>
    Wildcards mit * werden unterstützt, z. B. R-* oder Wifi*.
    Die Blacklist wird auf Device-Kontext, Control-Kontext und auf Gerätestatusabfragen angewendet.</li><br>

  <a id="Claude-attr-*._Instructions"></a>
    <li>&lt;Instanzname&gt;_Instructions<br>
    Optionales Attribut an beliebigen FHEM-Geräten.<br>
    Damit lassen sich gerätespezifische Anweisungen nur für diese Claude-Instanz hinterlegen.
    Das Attribut wird zusätzlich zum allgemeinen comment in den Device- und Control-Kontext übernommen.<br>
      Beispiel: Lautet der Name im define des Claude Moduls &quot;ClaudeAI&quot; (Instanzname), erscheint in FHEM-Geräten das Zusatzattribut ClaudeAI_Instructions.</li>
</ul><br>

=end html_DE

=begin html

<a id="Claude-readings"></a>
<b>Readings</b><br>
<ul>
  <li>response<br>
    Last text response from Claude (raw Markdown)</li><br>

  <li>responsePlain<br>
    Last text response with Markdown syntax removed (plain text, ideal for Telegram, notify, etc.)</li><br>

  <li>responseHTML<br>
    Last text response with Markdown converted to HTML (ideal for tablet UI, web frontends)</li><br>

  <li>responseSSML<br>
    Last text response cleaned for speech output and prepared as SSML</li><br>

  <li>state<br>
    Current status</li><br>

  <li>lastError<br>
    Last error</li><br>

  <li>chatHistory<br>
    Number of messages in the chat history</li><br>

  <li>lastCommand<br>
    Last executed set command (e.g. Lampe1 on)</li><br>

  <li>lastCommandResult<br>
    Result of the last set command (ok or error message)</li><br>
</ul><br>

<b>Additional Readings</b> (when the showAdvancedReadings attribute is set)
<ul>
  <li>lastRequestModel<br>
    Model name of the last request</li><br>

  <li>lastRequestType<br>
    Type of the last request, e.g. ask, askWithImage, askAboutDevices, or control</li><br>

  <li>lastRequestWasLocal<br>
    1 for local control execution without Claude API, otherwise 0</li><br>

  <li>lastApiCallUsedTools<br>
    1 if the last Claude API call used Tool Use, otherwise 0</li><br>

  <li>toolUseCount<br>
    Number of tool_use blocks contained in the last Claude control response</li><br>

  <li>toolSetDeviceCount<br>
    Number of set_device tool calls contained in the last Claude control response</li><br>

  <li>toolGetDeviceStateCount<br>
    Number of get_device_state tool calls contained in the last Claude control response</li><br>

  <li>responseId<br>
    Shows the Anthropic response ID. If an API response exceptionally does not contain an ID, or during local execution, this reading contains &quot;-&quot;.</li><br>

  <li>responseType<br>
    Shows the response type. For Anthropic responses this is normally message, and for local execution local.</li><br>

  <li>responseRole<br>
    Shows the role of the response. For Anthropic responses this is normally assistant, and for local execution also assistant.</li><br>

  <li>stopReason<br>
    Stop reason of the last Claude response. During local execution this is local.</li><br>

  <li>stopSequence<br>
    Shows the stop sequence at which Anthropic ended the response. If the response was not ended by a stop sequence or Anthropic does not send a value, this reading contains &quot;-&quot;.</li><br>

  <li>stopDetails<br>
    Shows additional details about the stop reason as JSON text. If Anthropic does not send additional details, this reading contains &quot;-&quot;.</li><br>

  <li>serviceTier<br>
    Shows the service tier reported by Anthropic, for example standard. If Anthropic does not send a value, this reading contains &quot;-&quot;.</li><br>

  <li>inferenceGeo<br>
    Shows the inference region reported by Anthropic or a backend hint such as not_available. If Anthropic does not send a value, this reading contains &quot;-&quot;.</li><br>

  <li>candidatesTokenCount<br>
    Number of tokens generated by Claude for the response</li><br>

  <li>promptTokenCount<br>
    Number of input tokens sent to Claude</li><br>

  <li>totalTokenCount<br>
    Total number of consumed tokens (input + output, optionally plus cache creation if provided)</li><br>

  <li>cacheCreationInputTokens<br>
    Shows how many input tokens were written into a new prompt cache. 0: the field was present, but no new cache portion was created for this request.</li><br>

  <li>cacheReadInputTokens<br>
    Shows how many input tokens were read from an existing prompt cache. 0: the field was present, but no cache was used for this request.</li><br>

  <li>cacheCreationEphemeral5mInputTokens<br>
    Shows how many input tokens were written into a 5-minute cache. 0: the subfield was present, but there was no matching cache portion for this request. If Anthropic does not provide this subfield, this reading contains &quot;-&quot;.</li><br>

  <li>cacheCreationEphemeral1hInputTokens<br>
    Shows how many input tokens were written into a 1-hour cache. 0: the subfield was present, but there was no matching cache portion for this request. If Anthropic does not provide this subfield, this reading contains &quot;-&quot;.</li>
</ul><br>

=end html

=begin html_DE

<a id="Claude-readings"></a>
<b>Readings</b><br>
<ul>
  <li>response<br>
    Letzte Textantwort von Claude (Roh-Markdown)</li><br>

  <li>responsePlain<br>
    Letzte Textantwort, Markdown-Syntax entfernt (reiner Text, ideal für Telegram, Notify, etc.)</li><br>

  <li>responseHTML<br>
    Letzte Textantwort, Markdown in HTML (ideal für Tablet-UI, Web-Frontends)</li><br>

  <li>responseSSML<br>
    Letzte Textantwort, für Sprachausgabe bereinigt und als SSML aufbereitet</li><br>

  <li>state<br>
    Aktueller Status</li><br>

  <li>lastError<br>
    Letzter Fehler</li><br>

  <li>chatHistory<br>
    Anzahl der Nachrichten im Chat-Verlauf</li><br>

  <li>lastCommand<br>
    Letzter ausgeführter set-Befehl (z. B. Lampe1 on)</li><br>

  <li>lastCommandResult<br>
    Ergebnis des letzten set-Befehls (ok oder Fehlermeldung)</li><br>
</ul><br>

<b>Zusätzliche Readings</b> (bei gesetztem Attribut showAdvancedReadings)
<ul>
  <li>lastRequestModel<br>
    Modellname des letzten Requests</li><br>

  <li>lastRequestType<br>
    Typ des letzten Requests, z. B. ask, askWithImage, askAboutDevices oder control</li><br>

  <li>lastRequestWasLocal<br>
    1 bei lokaler Control-Ausführung ohne Claude-API, sonst 0</li><br>

  <li>lastApiCallUsedTools<br>
    1, wenn der letzte Claude-API-Call Tool Use verwendet hat, sonst 0</li><br>

  <li>toolUseCount<br>
    Anzahl der im letzten Claude-Control-Response enthaltenen tool_use-Blöcke</li><br>

  <li>toolSetDeviceCount<br>
    Anzahl der im letzten Claude-Control-Response enthaltenen set_device-Toolaufrufe</li><br>

  <li>toolGetDeviceStateCount<br>
    Anzahl der im letzten Claude-Control-Response enthaltenen get_device_state-Toolaufrufe</li><br>

  <li>responseId<br>
      Zeigt die Anthropic-Antwort-ID. Wenn bei einer API-Antwort ausnahmsweise keine ID geliefert wird, oder bei lokaler Ausführung, steht hier &quot;-&quot;.</li><br>

  <li>responseType<br>
    Zeigt den Antworttyp. Bei Anthropic-Antworten ist das normalerweise message, bei lokaler Ausführung local.</li><br>

  <li>responseRole<br>
    Zeigt die Rolle der Antwort. Bei Anthropic-Antworten ist das normalerweise assistant, bei lokaler Ausführung ebenfalls assistant.</li><br>

  <li>stopReason<br>
    Stop-Grund der letzten Claude-Antwort. Bei lokaler Ausführung steht hier local.</li><br>

  <li>stopSequence<br>
    Zeigt die Stop-Sequenz, an der Anthropic die Antwort beendet hat. Wenn die Antwort nicht wegen einer Stop-Sequenz beendet wurde oder Anthropic keinen Wert sendet, steht hier &quot;-&quot;.</li><br>

  <li>stopDetails<br>
    Zeigt zusätzliche Details zum Stoppgrund als JSON-Text. Wenn Anthropic keine Zusatzdetails sendet, steht hier &quot;-&quot;.</li><br>

  <li>serviceTier<br>
    Zeigt den von Anthropic gemeldeten Service-Tier, zum Beispiel standard. Wenn Anthropic keinen Wert sendet, steht hier &quot;-&quot;.</li><br>

  <li>inferenceGeo<br>
    Zeigt die von Anthropic gemeldete Inferenz-Region oder einen Backend-Hinweis wie not_available. Wenn Anthropic keinen Wert sendet, steht hier &quot;-&quot;.</li><br>

  <li>candidatesTokenCount<br>
    Anzahl der von Claude für die Antwort generierten Tokens</li><br>

  <li>promptTokenCount<br>
    Anzahl der an Claude gesendeten Input-Tokens</li><br>

  <li>totalTokenCount<br>
    Gesamtsumme der verbrauchten Tokens (Input + Output, optional zzgl. Cache-Erzeugung falls geliefert)</li><br>

  <li>cacheCreationInputTokens<br>
    Zeigt, wie viele Input-Tokens in einen neuen Prompt-Cache geschrieben wurden. 0: Das Feld wurde geliefert, aber für diesen Request wurde kein neuer Cache-Anteil erzeugt.</li><br>
 
  <li>cacheReadInputTokens<br>
    Zeigt, wie viele Input-Tokens aus einem vorhandenen Prompt-Cache gelesen wurden. 0: Das Feld wurde geliefert, aber für diesen Request wurde kein Cache genutzt.</li><br>

  <li>cacheCreationEphemeral5mInputTokens<br>
    Zeigt, wie viele Input-Tokens in einen 5-Minuten-Cache geschrieben wurden. 0: Das Unterfeld wurde geliefert, aber es gab für diesen Request keinen entsprechenden Cache-Anteil. Wenn Anthropic dieses Unterfeld nicht liefert, steht hier &quot;-&quot;.</li><br>

  <li>cacheCreationEphemeral1hInputTokens<br>
    Zeigt, wie viele Input-Tokens in einen 1-Stunden-Cache geschrieben wurden. 0: Das Unterfeld wurde geliefert, aber es gab für diesen Request keinen entsprechenden Cache-Anteil. Wenn Anthropic dieses Unterfeld nicht liefert, steht hier &quot;-&quot;.</li>
</ul><br>

=end html_DE
=cut
