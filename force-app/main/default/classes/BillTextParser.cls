/**
 * Turns pasted bill text into charge lines. Handles two layouts:
 *   1. Same line:   Office Visit - Established Patient   99213   $130.00
 *   2. Printed statement rows: 02/02/26  J0166  Description  1  16.30  (date, code, description, qty, amount)
 *   3. Portal copy: description on one line, "$130.00" on the next line, grouped under
 *                   category headings such as "Pharmacy-General Classification  /  $266.76".
 * Category heading lines carry the category total, so they are used as the category name
 * and are NOT returned as charges (that would count every category twice).
 * Cleaning: "HC " prefix, "- quantity: N" and drug codes like (0338-0117-04) are removed
 * from the description; "Hide charges" lines are ignored.
 */
public with sharing class BillTextParser {

    public class ParsedCharge {
        public String description;
        public String cptCode;
        public Decimal amount;
        public String category;
    }

    // Printed statement rows: date, optional CPT/HCPCS code, description, quantity, amount.
    //   02/02/26   J0166   Epinephrine 1 Mg/Ml Solution 1 Ml Ampule (54288-103-10)   1   16.30
    static final Pattern TABLE_ROW = Pattern.compile(
        '^\\d{1,2}/\\d{1,2}/\\d{2,4}\\s+(?:([A-Z]?\\d{4,5}[A-Z]?)\\s+)?(.+?)\\s+(\\d{1,4})\\s+\\$?([0-9,]+\\.\\d{2})\\s*$');
    static final Pattern SAME_LINE = Pattern.compile('^(.+?)\\s+(?:(\\d{5})\\s+)?\\$?([0-9,]+\\.\\d{2})\\s*$');
    static final Pattern AMOUNT_ONLY = Pattern.compile('^\\$?([0-9,]+\\.\\d{2})$');
    static final Pattern QUANTITY = Pattern.compile('(?i)\\s*-\\s*quantity:\\s*\\d+\\s*$');
    static final Pattern DRUG_CODE = Pattern.compile('\\s*\\(\\d{4,5}-\\d{3,4}-\\d{1,2}\\)');
    static final String CATEGORY_MARK = '-general classification';

    public static List<ParsedCharge> parse(String text) {
        List<ParsedCharge> out = new List<ParsedCharge>();
        if (String.isBlank(text)) {
            return out;
        }
        String pending = null;
        String category = null;
        Boolean inPayments = false; // inside an "Insurance/Patient Payments and Adjustments" block

        for (String raw : text.split('\n')) {
            String line = raw == null ? '' : raw.trim();
            if (line.length() == 0) {
                continue;
            }
            String lower = line.toLowerCase();
            if (lower == 'hide charges' || lower == 'show charges') {
                pending = null;
                continue;
            }

            // Full statements: payments, adjustments and totals are not charges.
            if (lower.contains('payments and adjustments')) {
                inPayments = true;
                pending = null;
                continue;
            }
            if (lower == 'charges' || lower.startsWith('admission to') || lower.startsWith('charges for visit')) {
                inPayments = false;
                pending = null;
                if (lower.startsWith('admission to')) {
                    category = null; // a new admission starts with no doctor heading
                }
                if (lower.startsWith('charges for visit with ')) {
                    // professional charges: group them under the doctor's name
                    category = 'Doctor: ' + line.substring('charges for visit with '.length()).trim();
                }
                continue;
            }
            if (inPayments || lower.startsWith('total ') || lower.contains('coinsurance:')) {
                pending = null;
                continue;
            }

            Matcher am = AMOUNT_ONLY.matcher(line);
            if (am.matches()) {
                if (pending != null) {
                    category = add(out, pending, null, toAmount(am.group(1)), category);
                }
                pending = null;
                continue;
            }

            Matcher tm = TABLE_ROW.matcher(line);
            if (tm.matches()) {
                category = add(out, tm.group(2), tm.group(1), toAmount(tm.group(4)), category);
                pending = null;
                continue;
            }

            Matcher sm = SAME_LINE.matcher(line);
            if (sm.matches()) {
                category = add(out, sm.group(1), sm.group(2), toAmount(sm.group(3)), category);
                pending = null;
                continue;
            }

            pending = line;
        }
        return out;
    }

    // Adds a charge, or switches category when the line is a category total. Returns the current category.
    static String add(List<ParsedCharge> out, String description, String cpt, Decimal amount, String category) {
        String d = description.trim();
        // A real charge has words in its description; a row of bare numbers is a summary line.
        if (!Pattern.compile('[A-Za-z]').matcher(d).find()) {
            return category;
        }
        if (d.toLowerCase().contains(CATEGORY_MARK)) {
            Integer cut = d.toLowerCase().indexOf(CATEGORY_MARK);
            return d.substring(0, cut).trim();
        }
        d = QUANTITY.matcher(d).replaceAll('');
        d = DRUG_CODE.matcher(d).replaceAll('');
        if (d.startsWith('HC ')) {
            d = d.substring(3);
        }
        d = d.trim();
        if (d.length() == 0) {
            return category;
        }
        ParsedCharge pc = new ParsedCharge();
        pc.description = d.abbreviate(250);
        pc.cptCode = cpt;
        pc.amount = amount;
        pc.category = category;
        out.add(pc);
        return category;
    }

    static Decimal toAmount(String s) {
        return Decimal.valueOf(s.replace(',', ''));
    }
}