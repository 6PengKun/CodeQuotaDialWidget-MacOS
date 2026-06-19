import Testing
@testable import AntigravityQuotaCore

struct AntigravityQuotaParserTests {
    @Test
    func parsesTargetModelQuotasFromLocalUserStatus() throws {
        let body = """
        {
          "userStatus": {
            "email": "user@example.com",
            "planStatus": {
              "planInfo": {
                "planType": "pro"
              }
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "modelOrAlias": { "model": "claude-opus-4.1" },
                  "label": "Claude Opus 4.1",
                  "quotaInfo": {
                    "remainingFraction": 0.82,
                    "resetTime": "2026-06-19T12:00:00Z"
                  }
                },
                {
                  "modelOrAlias": { "model": "claude-sonnet-4" },
                  "label": "Claude Sonnet 4",
                  "quotaInfo": {
                    "remainingFraction": 0.25,
                    "resetTime": "2026-06-19T13:00:00Z"
                  }
                },
                {
                  "modelOrAlias": { "model": "gemini-3-pro" },
                  "label": "Gemini 3 Pro",
                  "quotaInfo": {
                    "remainingFraction": 0.55,
                    "resetTime": "2026-06-19T14:00:00Z"
                  }
                },
                {
                  "modelOrAlias": { "model": "gemini-3-flash" },
                  "label": "Gemini 3 Flash",
                  "quotaInfo": {
                    "remainingFraction": 1.0,
                    "resetTime": "2026-06-19T15:00:00Z"
                  }
                }
              ]
            }
          }
        }
        """

        let snapshot = try AntigravityQuotaCollector.parseUserStatusResponse(body)

        #expect(snapshot.error == nil)
        #expect(snapshot.email == "user@example.com")
        #expect(snapshot.planType == "pro")
        #expect(snapshot.model(for: .opus)?.remainingPercent == 82)
        #expect(snapshot.model(for: .sonnet)?.usedPercent == 75)
        #expect(snapshot.model(for: .pro)?.remainingPercent == 55)
        #expect(snapshot.model(for: .flash)?.remainingPercent == 100)
        #expect(snapshot.model(for: .claude)?.modelId == "claude-sonnet-4")
        #expect(snapshot.model(for: .claude)?.remainingPercent == 25)
        #expect(snapshot.model(for: .gemini)?.modelId == "gemini-3-pro")
        #expect(snapshot.model(for: .gemini)?.remainingPercent == 55)
    }

    @Test
    func skipsAutocompleteAndKeepsMostConservativeQuotaPerFamily() throws {
        let body = """
        {
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "modelOrAlias": { "model": "gemini-2.5-pro-autocomplete" },
                  "label": "Gemini 2.5 Pro Autocomplete",
                  "quotaInfo": { "remainingFraction": 0.01 }
                },
                {
                  "modelOrAlias": { "model": "gemini-3-pro" },
                  "label": "Gemini 3 Pro",
                  "quotaInfo": { "remainingFraction": 0.72 }
                },
                {
                  "modelOrAlias": { "model": "gemini-3-pro-preview" },
                  "label": "Gemini 3 Pro Preview",
                  "quotaInfo": { "remainingFraction": 0.31 }
                },
                {
                  "modelOrAlias": { "model": "tab_gemini_flash" },
                  "label": "Gemini Flash Tab",
                  "quotaInfo": { "remainingFraction": 0.02 }
                },
                {
                  "modelOrAlias": { "model": "gemini-3-flash" },
                  "label": "Gemini 3 Flash",
                  "quotaInfo": { "remainingFraction": 0.64 }
                }
              ]
            }
          }
        }
        """

        let snapshot = try AntigravityQuotaCollector.parseUserStatusResponse(body)

        #expect(snapshot.model(for: .pro)?.modelId == "gemini-3-pro-preview")
        #expect(snapshot.model(for: .pro)?.remainingPercent == 31)
        #expect(snapshot.model(for: .flash)?.modelId == "gemini-3-flash")
        #expect(snapshot.model(for: .flash)?.remainingPercent == 64)
    }
}
