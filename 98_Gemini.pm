# Versionshistorie
# 2.0.2 - 2026-04-09  Fix: gesamtes content-Objekt der Modell-Antwort im Chat
#                          speichern (statt nur functionCall) für korrekte
#                          Multi-Turn Function Calling Konversation

    $hash->{VERSION} = '2.0.2';

    in Gemini_HandleControlResponse, replace these lines:
            # Modell-Antwort (gesamtes content-Objekt) in Chat-Verlauf speichern
            push @{$hash->{CHAT}}, $content;