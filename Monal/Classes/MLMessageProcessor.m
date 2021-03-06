//
//  MLMessageProcessor.m
//  Monal
//
//  Created by Anurodh Pokharel on 9/1/19.
//  Copyright © 2019 Monal.im. All rights reserved.
//

#import "MLMessageProcessor.h"
#import "DataLayer.h"
#import "SignalAddress.h"
#import "HelperTools.h"
#import "AESGcm.h"
#import "MLConstants.h"
#import "MLImageManager.h"
#import "XMPPIQ.h"
#import "MLPubSub.h"
#import "MLOMEMO.h"
#import "MLFiletransfer.h"

@interface MLPubSub ()
-(void) handleHeadlineMessage:(XMPPMessage*) messageNode;
@end

static NSMutableDictionary* _typingNotifications;

@implementation MLMessageProcessor

+(void) initialize
{
    _typingNotifications = [[NSMutableDictionary alloc] init];
}

+(void) processMessage:(XMPPMessage*) messageNode andOuterMessage:(XMPPMessage*) outerMessageNode forAccount:(xmpp*) account
{
    if([messageNode check:@"/<type=error>"])
    {
        DDLogError(@"Error type message received");
        
        if(![messageNode check:@"/@id"])
        {
            DDLogError(@"Ignoring error messages having an empty ID");
            return;
        }
        
        NSString* errorType = [messageNode findFirst:@"error@type"];
        NSString* errorReason = [messageNode findFirst:@"error/{urn:ietf:params:xml:ns:xmpp-stanzas}!text$"];
        NSString* errorText = [messageNode findFirst:@"error/{urn:ietf:params:xml:ns:xmpp-stanzas}text#"];
        DDLogInfo(@"Got errorType='%@', errorReason='%@', errorText='%@' for message '%@'", errorType, errorReason, errorText, [messageNode findFirst:@"/@id"]);
        
        if(errorReason)
            errorType = [NSString stringWithFormat:@"%@ - %@", errorType, errorReason];
        if(!errorText)
            errorText = NSLocalizedString(@"No further error description", @"");
        
        if(!errorType) {
            errorType= @"Unknown error";
        }
        
        //update db
        [[DataLayer sharedInstance]
            setMessageId:[messageNode findFirst:@"/@id"]
            errorType:errorType
            errorReason:errorText
        ];
        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalMessageErrorNotice object:nil userInfo:@{
            @"MessageID": [messageNode findFirst:@"/@id"],
            @"errorType": errorType,
            @"errorReason": errorText
        }];

        return;
    }

    if([messageNode check:@"/<type=headline>/{http://jabber.org/protocol/pubsub#event}event"])
    {
        [account.pubsub handleHeadlineMessage:messageNode];
        return;
    }
    
    //ignore self messages after this (only pubsub data is from self)
    if([messageNode.fromUser isEqualToString:messageNode.toUser])
        return;
    
    //add contact if possible (ignore already existing contacts)
    [[DataLayer sharedInstance] addContact:messageNode.fromUser forAccount:account.accountNo nickname:nil andMucNick:nil];
    
    NSString* stanzaid = [outerMessageNode findFirst:@"{urn:xmpp:mam:2}result@id"];
    //check stanza-id @by according to the rules outlined in XEP-0359
    if(!stanzaid && [account.connectionProperties.identity.jid isEqualToString:[messageNode findFirst:@"{urn:xmpp:sid:0}stanza-id@by"]])
        stanzaid = [messageNode findFirst:@"{urn:xmpp:sid:0}stanza-id@id"];

    if([messageNode check:@"{http://jabber.org/protocol/muc#user}x/invite"])
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalReceivedMucInviteNotice object:nil userInfo:@{@"from": messageNode.from}];
        return;
    }

    NSString* decrypted;
    if([messageNode check:@"/{jabber:client}message/{eu.siacs.conversations.axolotl}encrypted/header"])
    {
        NSString* queryId = [outerMessageNode findFirst:@"{urn:xmpp:mam:2}result@queryid"];
        if(queryId && [queryId hasPrefix:@"MLhistory:"]) {
            decrypted = NSLocalizedString(@"Message was encrypted with omemo and can't be decrypted anymore", @"");
        } else {
            decrypted = [account.omemo decryptMessage:messageNode];
        }
    }

    if([messageNode check:@"body"] || [messageNode check:@"/<type=headline>/subject#"] || decrypted)
    {
        NSString* ownNick;
        NSString* actualFrom = messageNode.fromUser;
        
        //processed messages already have server name
        if([messageNode check:@"/<type=groupchat>"] && messageNode.fromResource)
        {
            ownNick = [[DataLayer sharedInstance] ownNickNameforMuc:messageNode.fromUser andServer:@"" forAccount:account.accountNo];
            actualFrom = messageNode.fromResource;
        }
        if(ownNick && actualFrom && [actualFrom isEqualToString:ownNick])
        {
            DDLogDebug(@"Dropping muc echo");
            return;
        }
        else
        {
            BOOL unread = YES;
            BOOL showAlert = YES;
            
            //if incoming or mam catchup we do want an alert, otherwise we don't
            if(
                [messageNode.fromUser isEqualToString:account.connectionProperties.identity.jid] ||
                (
                    [outerMessageNode check:@"{urn:xmpp:mam:2}result"] &&
                    ![[outerMessageNode findFirst:@"{urn:xmpp:mam:2}result@queryid"] hasPrefix:@"MLcatchup:"]
                )
            )
            {
                DDLogVerbose(@"Setting showAlert to NO");
                showAlert = NO;
                unread = NO;
            }
          
            NSString* messageType = kMessageTypeText;
            BOOL encrypted = NO;
            NSString* body = [messageNode findFirst:@"body#"];
            
            if(decrypted)
            {
                body = decrypted;
                encrypted = YES;
            }
            
            if(!body && [messageNode check:@"/<type=headline>/subject#"])
            {
                NSString* subject = [messageNode findFirst:@"/<type=headline>/subject#"];
                NSString* currentSubject = [[DataLayer sharedInstance] mucSubjectforAccount:account.accountNo andRoom:messageNode.fromUser];
                if(!subject || [subject isEqualToString:currentSubject])
                    return;
                
                [[DataLayer sharedInstance] updateMucSubject:subject forAccount:account.accountNo andRoom:messageNode.fromUser];
                //TODO: this stuff has to be changed (why send a kMonalNewMessageNotice instead of a special kMonalMucSubjectChanged one?)
                MLMessage* message = [account parseMessageToMLMessage:messageNode withBody:subject andEncrypted:encrypted andMessageType:kMessageTypeStatus andActualFrom:actualFrom];
                [[NSNotificationCenter defaultCenter] postNotificationName:kMonalNewMessageNotice object:account userInfo:@{
                    @"message": message,
                    @"subject": subject,
                }];
                return;
            }
            
            //messages with oob tag are filetransfers (but only if they are https urls)
            NSString* lowercaseBody = [body lowercaseString];
            if(body && [body isEqualToString:[messageNode findFirst:@"{jabber:x:oob}x/url#"]] && [lowercaseBody hasPrefix:@"https://"])
                messageType = kMessageTypeFiletransfer;
            //messages without spaces are potentially special ones
            else if([body rangeOfString:@" "].location == NSNotFound)
            {
                if([lowercaseBody hasPrefix:@"geo:"])
                    messageType = kMessageTypeGeo;
                //encrypted messages having one single string prefixed with "aesgcm:" are filetransfers, too (tribal knowledge)
                else if(encrypted && [lowercaseBody hasPrefix:@"aesgcm://"])
                    messageType = kMessageTypeFiletransfer;
                else if([lowercaseBody hasPrefix:@"https://"])
                    messageType = kMessageTypeUrl;
            }
            DDLogInfo(@"Got message of type: %@", messageType);
            
            NSString* messageId = [messageNode findFirst:@"/@id"];
            if(!messageId.length)
            {
                DDLogWarn(@"Empty ID using random UUID");
                messageId = [[NSUUID UUID] UUIDString];
            }
            
            //history messages have to be collected mam-page wise and reordered before inserted into db
            //because mam always sorts the messages in a page by timestamp in ascending order
            //we don't want to call postPersistAction, too, beause we don't want to display push notifications for old messages
            if([outerMessageNode check:@"{urn:xmpp:mam:2}result"] && [[outerMessageNode findFirst:@"{urn:xmpp:mam:2}result@queryid"] hasPrefix:@"MLhistory:"])
            {
                DDLogInfo(@"Adding message to mam page array to be inserted into history later on");
                [account addMessageToMamPageArray:messageNode forOuterMessageNode:outerMessageNode withBody:body andEncrypted:encrypted andMessageType:messageType];
                return;
            }
            
            if(body)
            {
                NSNumber* historyId = nil;
                
                //handle LMC
                BOOL deleteMessage = NO;
                if([messageNode check:@"{urn:xmpp:message-correct:0}replace"])
                {
                    NSString* messageIdToReplace = [messageNode findFirst:@"{urn:xmpp:message-correct:0}replace@id"];
                    historyId = [[DataLayer sharedInstance] getHistoryIDForMessageId:messageIdToReplace from:messageNode.fromUser andAccount:account.accountNo];
                    if([[DataLayer sharedInstance] checkLMCEligible:historyId from:messageNode.fromUser])
                    {
                        if(![body isEqualToString:kMessageDeletedBody])
                            [[DataLayer sharedInstance] updateMessageHistory:historyId withText:body];
                        else
                            deleteMessage = YES;
                    }
                    else
                        historyId = nil;
                }
                
                //handle normal messages or LMC messages that can not be found (but ignore deletion LMCs)
                if(historyId == nil && ![body isEqualToString:kMessageDeletedBody])
                {
                    historyId = [[DataLayer sharedInstance]
                             addMessageFrom:messageNode.fromUser
                                         to:messageNode.toUser
                                 forAccount:account.accountNo
                                   withBody:[body copy]
                               actuallyfrom:actualFrom
                                       sent:YES
                                     unread:unread
                                  messageId:messageId
                            serverMessageId:stanzaid
                                messageType:messageType
                            andOverrideDate:[messageNode findFirst:@"{urn:xmpp:delay}delay@stamp|datetime"]
                                  encrypted:encrypted
                                  backwards:NO
                        displayMarkerWanted:[messageNode check:@"{urn:xmpp:chat-markers:0}markable"]
                    ];
                }
                
                MLMessage* message = [[DataLayer sharedInstance] messageForHistoryID:historyId];
                if(message != nil && historyId != nil)      //check historyId to make static analyzer happy
                {
                    if(
                        [[HelperTools defaultsDB] boolForKey:@"SendReceivedMarkers"] &&
                        ([messageNode check:@"{urn:xmpp:receipts}request"] || [messageNode check:@"{urn:xmpp:chat-markers:0}markable"]) &&
                        ![messageNode.fromUser isEqualToString:account.connectionProperties.identity.jid]
                    )
                    {
                        XMPPMessage* receiptNode = [[XMPPMessage alloc] init];
                        //the message type is needed so that the store hint is accepted by the server --> mirror the incoming type
                        receiptNode.attributes[@"type"] = [messageNode findFirst:@"/@type"];
                        receiptNode.attributes[@"to"] = messageNode.fromUser;
                        if([messageNode check:@"{urn:xmpp:receipts}request"])
                            [receiptNode setReceipt:[messageNode findFirst:@"/@id"]];
                        if([messageNode check:@"{urn:xmpp:chat-markers:0}markable"])
                            [receiptNode setChatmarkerReceipt:[messageNode findFirst:@"/@id"]];
                        [receiptNode setStoreHint];
                        [account send:receiptNode];
                    }

                    //check if we have an outgoing message sent from another client on our account
                    //if true we can mark all messages from this buddy as already read by us (using the other client)
                    //WARNING: kMonalMessageDisplayedNotice goes to chatViewController, kMonalDisplayedMessageNotice goes to MLNotificationManager and activeChatsViewController/chatViewController
                    //e.g.: kMonalMessageDisplayedNotice means "remote party read our message" and kMonalDisplayedMessageNotice means "we read a message"
                    if(body && stanzaid && ![messageNode.toUser isEqualToString:account.connectionProperties.identity.jid])
                    {
                        DDLogInfo(@"Got outgoing message to contact '%@' sent by another client, removing all notifications for unread messages of this contact", messageNode.toUser);
                        NSArray* unread = [[DataLayer sharedInstance] markMessagesAsReadForBuddy:messageNode.toUser andAccount:account.accountNo tillStanzaId:stanzaid wasOutgoing:NO];
                        DDLogDebug(@"Marked as read: %@", unread);
                        
                        //remove notifications of all remotely read messages (indicated by sending a response message)
                        for(MLMessage* msg in unread)
                            [[NSNotificationCenter defaultCenter] postNotificationName:kMonalDisplayedMessageNotice object:account userInfo:@{@"message":msg}];
                        
                        //update unread count in active chats list
                        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalContactRefresh object:account userInfo:@{
                            @"contact": [[DataLayer sharedInstance] contactForUsername:messageNode.toUser forAccount:account.accountNo]
                        }];
                    }
                    
                    if(deleteMessage)
                    {
                        [[DataLayer sharedInstance] deleteMessageHistory:historyId];
                        
                        DDLogInfo(@"Sending out kMonalDeletedMessageNotice notification for historyId %@", historyId);
                        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalDeletedMessageNotice object:account userInfo:@{
                            @"message": message,
                        }];
                    }
                    else
                    {
                        if(![messageNode.fromUser isEqualToString:account.connectionProperties.identity.jid])
                            [[DataLayer sharedInstance] addActiveBuddies:messageNode.fromUser forAccount:account.accountNo];
                        else
                            [[DataLayer sharedInstance] addActiveBuddies:messageNode.toUser forAccount:account.accountNo];
                        
                        DDLogInfo(@"Sending out kMonalNewMessageNotice notification for historyId %@", historyId);
                        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalNewMessageNotice object:account userInfo:@{
                            @"message": message,
                            @"historyId": historyId,
                            @"showAlert": @(showAlert),
                        }];
                        
                        //try to automatically determine content type of filetransfers
                        //TODO JIM: this should be the config key to enable/disable auto downloads
                        if(messageType == kMessageTypeFiletransfer && [[HelperTools defaultsDB] boolForKey:@"AutodownloadFiletransfers"])
                            [MLFiletransfer checkMimeTypeAndSizeForHistoryID:historyId];
                    }
                }
            }
        }
    }
    
    if(
        ([messageNode check:@"{urn:xmpp:receipts}received@id"] || [messageNode check:@"{urn:xmpp:chat-markers:0}received@id"]) &&
        [messageNode.toUser isEqualToString:account.connectionProperties.identity.jid]
    )
    {
        //save in DB
        NSString* id;
        if([messageNode check:@"{urn:xmpp:receipts}received@id"])
        {
            id = [messageNode findFirst:@"{urn:xmpp:receipts}received@id"];
            [[DataLayer sharedInstance] setMessageId:id received:YES];
        }
        else
        {
            id = [messageNode findFirst:@"{urn:xmpp:chat-markers:0}received@id"];
            [[DataLayer sharedInstance] setMessageId:id received:YES];
        }
        //Post notice
        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalMessageReceivedNotice object:self userInfo:@{kMessageId:id}];
    }
    
    //incoming chat markers from contact
    //WARNING: kMonalMessageDisplayedNotice goes to chatViewController, kMonalDisplayedMessageNotice goes to MLNotificationManager and activeChatsViewController/chatViewController
    //e.g.: kMonalMessageDisplayedNotice means "remote party read our message" and kMonalDisplayedMessageNotice means "we read a message"
    if([messageNode check:@"{urn:xmpp:chat-markers:0}displayed@id"] && [messageNode.toUser isEqualToString:account.connectionProperties.identity.jid])
    {
        DDLogInfo(@"Got remote display marker from %@ for message id: %@", messageNode.fromUser, [messageNode findFirst:@"{urn:xmpp:chat-markers:0}displayed@id"]);
        NSArray* unread = [[DataLayer sharedInstance] markMessagesAsReadForBuddy:messageNode.fromUser andAccount:account.accountNo tillStanzaId:[messageNode findFirst:@"{urn:xmpp:chat-markers:0}displayed@id"] wasOutgoing:YES];
        DDLogDebug(@"Marked as displayed: %@", unread);
        for(MLMessage* msg in unread)
            [[NSNotificationCenter defaultCenter] postNotificationName:kMonalMessageDisplayedNotice object:account userInfo:@{@"message":msg, kMessageId:msg.messageId}];
    }
    
    //incoming chat markers from own account (carbon copy)
    //WARNING: kMonalMessageDisplayedNotice goes to chatViewController, kMonalDisplayedMessageNotice goes to MLNotificationManager and activeChatsViewController/chatViewController
    //e.g.: kMonalMessageDisplayedNotice means "remote party read our message" and kMonalDisplayedMessageNotice means "we read a message"
    if([messageNode check:@"{urn:xmpp:chat-markers:0}displayed@id"] && ![messageNode.toUser isEqualToString:account.connectionProperties.identity.jid])
    {
        DDLogInfo(@"Got OWN display marker from %@ for message id: %@", messageNode.toUser, [messageNode findFirst:@"{urn:xmpp:chat-markers:0}displayed@id"]);
        NSArray* unread = [[DataLayer sharedInstance] markMessagesAsReadForBuddy:messageNode.toUser andAccount:account.accountNo tillStanzaId:[messageNode findFirst:@"{urn:xmpp:chat-markers:0}displayed@id"] wasOutgoing:NO];
        DDLogDebug(@"Marked as read: %@", unread);
        
        //remove notifications of all remotely read messages (indicated by sending a display marker)
        for(MLMessage* msg in unread)
            [[NSNotificationCenter defaultCenter] postNotificationName:kMonalDisplayedMessageNotice object:account userInfo:@{@"message":msg}];
        
        //update unread count in active chats list
        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalContactRefresh object:account userInfo:@{
            @"contact": [[DataLayer sharedInstance] contactForUsername:messageNode.toUser forAccount:account.accountNo]
        }];
    }
    
    //ignore typing notifications when in appex
    if(![HelperTools isAppExtension])
    {
        //only use "is typing" messages when not older than 2 minutes (always allow "not typing" messages)
        if(
            [messageNode check:@"{http://jabber.org/protocol/chatstates}*"] &&
            [[DataLayer sharedInstance] checkCap:@"http://jabber.org/protocol/chatstates" forUser:messageNode.fromUser andAccountNo:account.accountNo]
        )
        {
            //deduce state
            BOOL composing = NO;
            if([@"active" isEqualToString:[messageNode findFirst:@"{http://jabber.org/protocol/chatstates}*$"]])
                composing = NO;
            else if([@"composing" isEqualToString:[messageNode findFirst:@"{http://jabber.org/protocol/chatstates}*$"]])
                composing = YES;
            else if([@"paused" isEqualToString:[messageNode findFirst:@"{http://jabber.org/protocol/chatstates}*$"]])
                composing = NO;
            else if([@"inactive" isEqualToString:[messageNode findFirst:@"{http://jabber.org/protocol/chatstates}*$"]])
                composing = NO;
            
            //handle state
            if(
                (
                    composing &&
                    (
                        ![messageNode check:@"{urn:xmpp:delay}delay@stamp"] ||
                        [[NSDate date] timeIntervalSinceDate:[messageNode findFirst:@"{urn:xmpp:delay}delay@stamp|datetime"]] < 120
                    )
                ) ||
                !composing
            )
            {
                [[NSNotificationCenter defaultCenter] postNotificationName:kMonalLastInteractionUpdatedNotice object:self userInfo:@{
                    @"jid": messageNode.fromUser,
                    @"accountNo": account.accountNo,
                    @"isTyping": composing ? @YES : @NO
                }];
                //send "not typing" notifications (kMonalLastInteractionUpdatedNotice) 60 seconds after the last isTyping was received
                @synchronized(_typingNotifications) {
                    //copy needed values into local variables to not retain self by our timer block
                    NSString* jid = messageNode.fromUser;
                    //abort old timer on new isTyping or isNotTyping message
                    if(_typingNotifications[messageNode.fromUser])
                        ((monal_void_block_t) _typingNotifications[messageNode.fromUser])();
                    //start a new timer for every isTyping message
                    if(composing)
                    {
                        _typingNotifications[messageNode.fromUser] = [HelperTools startTimer:60 withHandler:^{
                            [[NSNotificationCenter defaultCenter] postNotificationName:kMonalLastInteractionUpdatedNotice object:[[NSDate date] initWithTimeIntervalSince1970:0] userInfo:@{
                                @"jid": jid,
                                @"accountNo": account.accountNo,
                                @"isTyping": @NO
                            }];
                        }];
                    }
                }
            }
        }
    }
}

@end
