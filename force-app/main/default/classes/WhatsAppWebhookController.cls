/**
 * Public REST endpoint that Meta's WhatsApp Cloud API calls.
 * Deploy this behind a Salesforce Site (Guest User access) so it's reachable
 * without login. Meta calls two ways:
 *   GET  -> one-time verification handshake when you first configure the webhook URL in the
 *           Meta Developer portal. You echo back "hub.challenge" if "hub.verify_token" matches.
 *   POST -> actual incoming messages, delivery/read receipts, etc.
 *
 * URL you'll register with Meta will look like:
 *   https://<your-site-domain>.my.site.com/coveragechecker/services/apexrest/whatsapp/webhook
 */
@RestResource(urlMapping='/whatsapp/webhook')
global with sharing class WhatsAppWebhookController {

    // Must match the "Verify Token" entered in the Meta Developer portal's webhook config.
private static final String VERIFY_TOKEN = System.Label.WhatsApp_Verify_Token;
    // ---------------------------------------------------------------
    // GET: Meta's one-time webhook verification handshake
    // ---------------------------------------------------------------
    @HttpGet
    global static void handleVerification() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        String mode = req.params.get('hub.mode');
        String token = req.params.get('hub.verify_token');
        String challenge = req.params.get('hub.challenge');

        if (mode == 'subscribe' && token == VERIFY_TOKEN) {
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(challenge);
        } else {
            res.statusCode = 403;
            res.responseBody = Blob.valueOf('Verification failed');
        }
    }

    // ---------------------------------------------------------------
    // POST: incoming messages / status updates
    // ---------------------------------------------------------------
    @HttpPost
    global static void handleIncoming() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        // 1. Verify the request really came from Meta before trusting the body.
        //    Meta signs every webhook POST with your App Secret (HMAC-SHA256) in the
        //    X-Hub-Signature-256 header.
        String signatureHeader = req.headers.get('X-Hub-Signature-256');
        Blob bodyBlob = req.requestBody;

        if (!isValidSignature(bodyBlob, signatureHeader)) {
            res.statusCode = 401;
            res.responseBody = Blob.valueOf('Invalid signature');
            return;
        }

        // 2. Return 200 fast so Meta doesn't retry; do the slow work async.
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('EVENT_RECEIVED');

        String rawBody = bodyBlob.toString();

        // 3. Hand off to async so the webhook response isn't held up.
        processIncomingAsync(rawBody);
    }

    // ---------------------------------------------------------------
    // Signature verification
    // ---------------------------------------------------------------
    private static Boolean isValidSignature(Blob body, String signatureHeader) {
        if (String.isBlank(signatureHeader) || !signatureHeader.startsWith('sha256=')) {
            return false;
        }
        String providedSig = signatureHeader.substringAfter('sha256=');

        // App Secret lives in WhatsApp_Config__mdt (Default record), not hardcoded.
        String appSecret = WhatsApp_Config__mdt.getInstance('Default').App_Secret__c;

        Blob hmac = Crypto.generateMac('hmacSHA256', body, Blob.valueOf(appSecret));
        String computedSig = EncodingUtil.convertToHex(hmac);

        return computedSig.equalsIgnoreCase(providedSig);
    }

    // ---------------------------------------------------------------
    // Async processing: parse Meta's payload and hand each message to the event
    // ---------------------------------------------------------------
    @future(callout=true)
    public static void processIncomingAsync(String rawBody) {
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            List<Object> entries = (List<Object>) payload.get('entry');
            if (entries == null) return;

            for (Object entryObj : entries) {
                Map<String, Object> entry = (Map<String, Object>) entryObj;
                List<Object> changes = (List<Object>) entry.get('changes');
                if (changes == null) continue;

                for (Object changeObj : changes) {
                    Map<String, Object> change = (Map<String, Object>) changeObj;
                    Map<String, Object> value = (Map<String, Object>) change.get('value');

                    // Log delivery failures reported by Meta (status updates).
                    if (value != null && value.get('statuses') != null) {
                        for (Object stObj : (List<Object>) value.get('statuses')) {
                            Map<String, Object> st = (Map<String, Object>) stObj;
                            if ((String) st.get('status') == 'failed') {
                                ErrorLogger.log(
                                    'WhatsAppWebhookController',
                                    'Error',
                                    'WhatsApp message delivery failed',
                                    JSON.serialize(st.get('errors')),
                                    null
                                );
                            }
                        }
                    }

                    List<Object> messages = value != null ? (List<Object>) value.get('messages') : null;
                    if (messages == null) continue;

                    for (Object msgObj : messages) {
                        Map<String, Object> msg = (Map<String, Object>) msgObj;
                        String fromNumber = (String) msg.get('from');
                        String msgType = (String) msg.get('type');

                        String body = null;
                        if (msgType == 'text') {
                            Map<String, Object> textBlock = (Map<String, Object>) msg.get('text');
                            body = textBlock != null ? (String) textBlock.get('body') : null;
                        } else if (msgType == 'button') {
                            // Quick Reply button tap on a template message. Meta sends the
                            // button's label text here, so it is normalized into the same
                            // "body" variable and treated exactly like typed text.
                            Map<String, Object> buttonBlock = (Map<String, Object>) msg.get('button');
                            body = buttonBlock != null ? (String) buttonBlock.get('text') : null;
                        }
                        // Other types (image, location, unsupported, etc.) are ignored for now.

                        if (String.isNotBlank(fromNumber) && String.isNotBlank(body)) {
                            routeMessage(fromNumber, body);
                        }
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'WhatsApp webhook parse error: ' + e.getMessage()
                + ' | ' + e.getStackTraceString());
            ErrorLogger.logException('WhatsAppWebhookController.processIncomingAsync', e, null);
        }
    }

    // ---------------------------------------------------------------
    // Hands the message to the WhatsApp_Inbound__e Platform Event. A trigger on that event
    // runs the booking chat (WhatsAppConversationRouter) as an internal user, via
    // WhatsAppInboundTriggerConfig, because this endpoint runs as the site guest user and
    // guest users can't call the Prompt Builder template.
    // ---------------------------------------------------------------
    private static void routeMessage(String fromNumber, String messageBody) {
        Database.SaveResult sr = EventBus.publish(new WhatsApp_Inbound__e(
            Phone__c = fromNumber,
            Body__c = messageBody
        ));
        if (!sr.isSuccess()) {
            ErrorLogger.log('WhatsAppWebhookController.routeMessage', 'Error',
                'Could not publish WhatsApp_Inbound__e',
                String.valueOf(sr.getErrors()), null);
        }
    }
}