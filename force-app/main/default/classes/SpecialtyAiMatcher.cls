public without sharing class SpecialtyAiMatcher {

    private static final String TEMPLATE_API_NAME = 'Specialty_Matcher';
    private static final String ENDPOINT = 'callout:Self_Org_API/services/data/v65.0/einstein/prompt-templates/'
        + TEMPLATE_API_NAME + '/generations';

    public class Result {
        public List<String> specialties = new List<String>();
        public Boolean emergency = false;
        public Boolean usedAi = false;
    }

    public static Result match(String issueText, List<String> availableSpecialties) {
        Result res = new Result();
        if (String.isBlank(issueText) || availableSpecialties == null || availableSpecialties.isEmpty()) {
            return res;
        }
        String userInfo = 'running user: ' + UserInfo.getUserName() + ' (' + UserInfo.getUserType() + ')';
        try {
            Map<String, Object> body = new Map<String, Object>{
                'isPreview' => false,
                'inputParams' => new Map<String, Object>{
                    'valueMap' => new Map<String, Object>{
                        'Input:Issue_Text' => new Map<String, Object>{ 'value' => issueText.left(500) },
                        'Input:Specialty_List' => new Map<String, Object>{
                            'value' => String.join(availableSpecialties, '\n')
                        }
                    }
                },
                'additionalConfig' => new Map<String, Object>{ 'applicationName' => 'PromptBuilderPreview' }
            };

            HttpRequest req = new HttpRequest();
            req.setEndpoint(ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(60000);
            req.setBody(JSON.serialize(body));

            HttpResponse resp = new Http().send(req);
            if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
                logFailure('AI HTTP ' + resp.getStatusCode(),
                    userInfo + '\nissue: ' + issueText + '\nbody: ' + resp.getBody().left(1500));
                return res;
            }

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> gens = parsed.get('generations') instanceof List<Object>
                ? (List<Object>) parsed.get('generations') : null;
            if (gens == null || gens.isEmpty()) {
                logFailure('AI returned no generations', userInfo + '\nissue: ' + issueText);
                return res;
            }
            String text = String.valueOf(((Map<String, Object>) gens[0]).get('text'));
            if (String.isBlank(text)) {
                logFailure('AI returned empty text', userInfo + '\nissue: ' + issueText);
                return res;
            }
            Integer start = text.indexOf('{');
            Integer endIdx = text.lastIndexOf('}');
            if (start < 0 || endIdx < start) {
                logFailure('AI reply had no JSON', userInfo + '\nissue: ' + issueText + '\nreply: ' + text.left(500));
                return res;
            }
            Map<String, Object> answer =
                (Map<String, Object>) JSON.deserializeUntyped(text.substring(start, endIdx + 1));

            Map<String, String> byLower = new Map<String, String>();
            for (String s : availableSpecialties) {
                byLower.put(s.toLowerCase(), s);
            }
            Object rawList = answer.get('specialties');
            if (rawList instanceof List<Object>) {
                for (Object o : (List<Object>) rawList) {
                    String key = String.valueOf(o).trim().toLowerCase();
                    if (byLower.containsKey(key) && !res.specialties.contains(byLower.get(key))) {
                        res.specialties.add(byLower.get(key));
                    }
                }
            }
            res.emergency = (answer.get('emergency') == true);
            res.usedAi = true;
        } catch (Exception e) {
            logFailure('AI call failed: ' + e.getTypeName() + ': ' + e.getMessage(),
                userInfo + '\nissue: ' + issueText + '\n' + e.getStackTraceString());
            res = new Result();
        }
        return res;
    }

    private static void logFailure(String message, String details) {
        try {
            ErrorLogger.log('SpecialtyAiMatcher', 'Warning', message, details, null);
        } catch (Exception ignored) {
            System.debug(LoggingLevel.WARN, 'SpecialtyAiMatcher could not write Error Log: ' + ignored.getMessage());
        }
    }
}