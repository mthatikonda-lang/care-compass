/**
 * Sends outbound WhatsApp messages through Meta's Cloud API.
 *
 * Setup:
 *   - WhatsApp_Config__mdt, "Default" record, with:
 *       Phone_Number_Id__c -> the test/production Phone Number ID from Meta
 *       Access_Token_1__c  -> first part of the access token (Text fields max out at 255 chars)
 *       Access_Token_2__c  -> rest of the token; joined with part 1 by getToken().
 *                             Temporary tokens expire after 24 hours, so paste the new one
 *                             into both fields when you regenerate it
 *       App_Secret__c      -> used by WhatsAppWebhookController for signature checks
 *   - Remote Site Setting (or equivalent) allowing https://graph.facebook.com
 *
 * The token is sent in an Authorization: Bearer header. It is never put in the URL and
 * never written to the debug log.
 *
 * Free-form text only works within 24 hours of the patient's last inbound message.
 * Outside that window, Meta requires a pre-approved message TEMPLATE — see
 * sendTemplateMessage().
 *
 * NOTE: makes an HTTP callout, so it cannot run in a transaction that has uncommitted DML.
 * WhatsAppConversationRouter handles this by enqueueing WhatsAppReplySender.
 */
public with sharing class WhatsAppSender {

    private static final String API_VERSION = 'v26.0';
    private static final String GRAPH_BASE_URL = 'https://graph.facebook.com';

    public class WhatsAppSendException extends Exception {}

    /**
     * Free-form text reply. Only valid inside the 24-hour customer service window.
     */
    public static void sendTextMessage(String toNumber, String messageText) {
        WhatsApp_Config__mdt config = getConfig();

        Map<String, Object> payload = new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to' => toNumber,
            'type' => 'text',
            'text' => new Map<String, Object>{ 'body' => messageText }
        };

        sendCallout(config.Phone_Number_Id__c, getToken(config), payload);
    }

    /**
     * Template message — required for the FIRST message to a patient, or any message sent
     * more than 24 hours after their last reply. The template must already be created and
     * approved in Meta Business Manager.
     *
     * bodyParams fill the {{1}}, {{2}}, ... placeholders of the template body, in order.
     * Pass null or an empty list for templates without placeholders.
     */
    public static void sendTemplateMessage(
        String toNumber, String templateName, String languageCode, List<String> bodyParams
    ) {
        WhatsApp_Config__mdt config = getConfig();

        Map<String, Object> template = new Map<String, Object>{
            'name' => templateName,
            'language' => new Map<String, Object>{ 'code' => languageCode }
        };

        if (bodyParams != null && !bodyParams.isEmpty()) {
            List<Object> parameters = new List<Object>();
            for (String p : bodyParams) {
                parameters.add(new Map<String, Object>{ 'type' => 'text', 'text' => p });
            }
            template.put('components', new List<Object>{
                new Map<String, Object>{ 'type' => 'body', 'parameters' => parameters }
            });
        }

        Map<String, Object> payload = new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to' => toNumber,
            'type' => 'template',
            'template' => template
        };

        sendCallout(config.Phone_Number_Id__c, getToken(config), payload);
    }

    // ---------------------------------------------------------------
    private static WhatsApp_Config__mdt getConfig() {
        WhatsApp_Config__mdt config = WhatsApp_Config__mdt.getInstance('Default');
        if (config == null || String.isBlank(config.Phone_Number_Id__c) || String.isBlank(getToken(config))) {
            throw new WhatsAppSendException(
                'WhatsApp_Config__mdt "Default" is missing Phone_Number_Id__c or the access token ' +
                '(Access_Token_1__c + Access_Token_2__c).'
            );
        }
        return config;
    }

    /**
     * Meta access tokens are longer than a 255-character Text field, so the token is stored
     * in two fields and joined here: Access_Token_1__c (first part) + Access_Token_2__c (rest).
     */
    private static String getToken(WhatsApp_Config__mdt config) {
        String part1 = config.Access_Token_1__c == null ? '' : config.Access_Token_1__c.trim();
        String part2 = config.Access_Token_2__c == null ? '' : config.Access_Token_2__c.trim();
        return part1 + part2;
    }

    private static void sendCallout(String phoneNumberId, String accessToken, Map<String, Object> payload) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(GRAPH_BASE_URL + '/' + API_VERSION + '/' + phoneNumberId + '/messages');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(20000);
        req.setBody(JSON.serialize(payload));

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            // Body is safe to log: Meta's error responses don't echo the token.
            String msg = 'WhatsApp send failed. Status ' + res.getStatusCode() + ': ' + res.getBody();
            System.debug(LoggingLevel.ERROR, msg);
            throw new WhatsAppSendException(msg);
        }
    }
}