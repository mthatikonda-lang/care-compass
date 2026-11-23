trigger WhatsAppInboundTrigger on WhatsApp_Inbound__e (after insert) {
    for (WhatsApp_Inbound__e e : Trigger.new) {
        System.enqueueJob(new WhatsAppInboundProcessor(e.Phone__c, e.Body__c));
    }
}