/**
 * Reads the text from an uploaded bill (PDF, PNG or JPG) by sending it to the OCR.space
 * text-reading service. Nothing is saved in Salesforce: the file comes in as base64, goes out
 * in the callout, and only the text comes back to the page.
 *
 * Setup: a Remote Site Setting for https://api.ocr.space and the custom label OCR_Space_API_Key.
 * The page then puts the text into the bill line items box, and CoverageCheckerController
 * analyses it as usual.
 */
public with sharing class BillFileReader {

    public class BillFileException extends Exception {}

    static final String ENDPOINT = 'https://api.ocr.space/parse/image';
    // About 1 MB of file once base64-encoded; the free OCR.space plan rejects larger files.
    static final Integer MAX_BASE64_CHARS = 1400000;
    static final Set<String> ALLOWED_TYPES = new Set<String>{ 'application/pdf', 'image/png', 'image/jpeg' };

    @AuraEnabled
    public static String readBill(String base64Data, String mimeType) {
        try {
            if (String.isBlank(base64Data)) {
                throw new BillFileException('No file was received. Please choose a file and try again.');
            }
            String mime = String.isBlank(mimeType) ? '' : mimeType.toLowerCase().trim();
            if (!ALLOWED_TYPES.contains(mime)) {
                throw new BillFileException('Please upload a PDF, PNG or JPG file.');
            }
            if (base64Data.length() > MAX_BASE64_CHARS) {
                throw new BillFileException('That file is too large to read. Please upload a smaller file, or paste the line items instead.');
            }
            String apiKey = System.Label.OCR_Space_API_Key;
            if (String.isBlank(apiKey)) {
                throw new BillFileException('Bill reading is not set up yet. Please paste the line items instead.');
            }

            HttpRequest req = new HttpRequest();
            req.setEndpoint(ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setTimeout(60000);
            req.setBody(
                'apikey=' + EncodingUtil.urlEncode(apiKey, 'UTF-8')
                + '&language=eng'
                + '&OCREngine=2'
                + '&isTable=true'
                + '&base64Image=' + EncodingUtil.urlEncode('data:' + mime + ';base64,' + base64Data, 'UTF-8')
            );

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                throw new BillFileException('The bill reading service is not available right now. Please paste the line items instead.');
            }
            return extractText(res.getBody());

        } catch (BillFileException e) {
            throw aura(e.getMessage());
        } catch (Exception e) {
            // Never put the file or the key in a message or log.
            System.debug(LoggingLevel.ERROR, 'BillFileReader.readBill failed: ' + e.getTypeName());
            throw aura('We could not read that file. You can paste the line items from your bill instead.');
        }
    }

    // Pulls the text out of the OCR.space response, or throws a readable message.
    @TestVisible
    static String extractText(String responseBody) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(responseBody);

        Object failed = body.get('IsErroredOnProcessing');
        if (failed instanceof Boolean && (Boolean) failed) {
            String why = '';
            Object msg = body.get('ErrorMessage');
            if (msg instanceof List<Object>) {
                List<String> parts = new List<String>();
                for (Object o : (List<Object>) msg) {
                    parts.add(String.valueOf(o));
                }
                why = String.join(parts, ' ');
            } else if (msg != null) {
                why = String.valueOf(msg);
            }
            throw new BillFileException('We could not read that file' + (String.isBlank(why) ? '.' : ': ' + why)
                + ' You can paste the line items instead.');
        }

        List<String> pages = new List<String>();
        Object parsed = body.get('ParsedResults');
        if (parsed instanceof List<Object>) {
            for (Object o : (List<Object>) parsed) {
                Map<String, Object> page = (Map<String, Object>) o;
                String text = (String) page.get('ParsedText');
                if (String.isNotBlank(text)) {
                    pages.add(text);
                }
            }
        }
        if (pages.isEmpty()) {
            throw new BillFileException('We could not find any text in that file. You can paste the line items instead.');
        }
        return String.join(pages, '\n');
    }

    static AuraHandledException aura(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}