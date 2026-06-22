import { LightningElement, wire } from 'lwc';
import { publish, MessageContext } from 'lightning/messageService';
import REFRESH from '@salesforce/messageChannel/RegieRefresh__c';

export default class RegieRefreshPublisher extends LightningElement {
    @wire(MessageContext) messageContext;
    connectedCallback() {
        publish(this.messageContext, REFRESH, { refresh: true });
    }
}