# Care Compass

Care Compass helps patients see what a doctor visit or a medical bill is likely to cost **before** they pay it. It checks a patient's insurance plan, finds in-network doctors, and shows an estimated out-of-pocket cost with the reasoning behind it.

Built as an MSIT capstone project on Salesforce (Experience Cloud, Lightning Web Components, Apex, Flow and Prompt Builder).

**Live app:** https://orgfarm-6b0663963a-dev-ed.develop.my.site.com/coveragechecker/welcome

> Care Compass gives **estimates, not final bills**. Real costs depend on your insurer's final claim decision.

## What it does

- **Cost estimate** for a visit, based on the patient's plan (deductible, copay, coinsurance, out-of-pocket maximum) and coverage rules.
- **Doctor search** by specialty or by doctor name, with an In-Network badge for the patient's plan.
- **Specialty matcher**: the patient describes a problem in plain words and a Prompt Builder template suggests the right kind of specialist.
- **Bill checker**: upload a PDF or a photo of a bill; the app reads the text, matches charges to procedure codes, and flags charges that look high against price benchmarks.
- **Booking** from the web app or over **WhatsApp**, with confirmation and reminder emails.
- **Patient accounts** with email verification, profile and insurance setup, and a dashboard of saved estimates and bills.

## Tech stack

| Area | What is used |
|---|---|
| Front end | Lightning Web Components on an Experience Cloud site |
| Back end | Apex controllers and triggers, platform events, scheduled reminder job |
| Automation | Flow (`Calculate_Appointment_Cost_Estimate`) |
| AI | Prompt Builder template `Specialty_Matcher` |
| Data | Custom objects for patients, doctors, providers, insurance plans, coverage rules, prices, bills, charges, appointments and WhatsApp conversations; big objects for large network and ZIP lookups |
| Messaging | WhatsApp Business Cloud API (Meta Graph API) |
| Bill reading | OCR.space API, plus Tesseract.js and PDF.js as static resources |

## Repository layout

```
force-app/main/default/
  classes/            Apex controllers, helpers, WhatsApp handlers, tests
  triggers/           Patient, WhatsApp and error-log triggers
  lwc/                Front-end components (landing page, coverage checker, booking, dashboard, ...)
  flows/              Cost estimate flow
  genAiPromptTemplates/  Specialty matcher prompt
  objects/            Custom objects, fields, validation rules
  staticresources/    Tesseract.js, PDF.js, bill reader page
  labels/             Custom labels (placeholders only, see below)
manifest/package.xml  Metadata manifest used to retrieve this project
```

## Setting it up in your own org

This repo has **no secrets**. Values that belong to one org were left out or replaced with placeholders, so you add your own:

1. **Deploy** the metadata with Salesforce CLI (`sf project deploy start --manifest manifest/package.xml`). Create your own Experience Cloud site and Auth Provider; those are not included.
2. **Named Credential `Self_Org_API`**: set up your own credential and Auth Provider for it.
3. **Custom metadata `Registration_Setting`**: set `Patient_Portal_Account_Id__c` and `Patient_Profile_Id__c` to the record IDs in your org.
4. **Custom label `OCR_Space_API_Key`**: replace `YOUR_OCR_SPACE_API_KEY` with your own key from OCR.space.
5. **WhatsApp**: create a Meta app with the WhatsApp Business Cloud API, then
   - create the custom metadata record `WhatsApp_Config` (`Default`) with your `Phone_Number_Id__c`, `App_Secret__c` and access token (`Access_Token_1__c` and `Access_Token_2__c`); that record is not in this repo,
   - set the verify token in the custom label `WhatsApp_Verify_Token`,
   - point the Meta webhook at your org's `WhatsApp_Webhook` site.
6. **Remote sites** `Meta_Graph_API` and `OCR_Space` are included; keep them active.
7. Load your own doctor, plan, coverage-rule and price data. Sample data is not included.

Never commit real keys or tokens. Use placeholders in the repo and put the real values into your org only.

## Testing

Apex test classes are in `force-app/main/default/classes/` (names ending in `Test`). Jest tests for some components are in each component's `__tests__` folder.

## Credits

- [Tesseract.js](https://github.com/naptha/tesseract.js) for in-browser text recognition
- [PDF.js](https://mozilla.github.io/pdf.js/) for reading PDF bills
- [OCR.space](https://ocr.space) for the OCR API
- Salesforce platform, Prompt Builder and Experience Cloud
- Public price and coverage reference data used for benchmarks and examples

Bill photos and PDFs are sent to OCR.space to be read, so please don't upload real personal bills to a demo site.

## Author

Manusha Thatikonda, MS in Information Technology, Clark University.
