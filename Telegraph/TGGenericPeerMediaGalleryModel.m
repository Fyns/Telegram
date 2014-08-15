#import "TGGenericPeerMediaGalleryModel.h"

#import "ActionStage.h"
#import "SGraphObjectNode.h"

#import "ATQueue.h"

#import "TGDatabase.h"
#import "TGAppDelegate.h"
#import "TGTelegraph.h"

#import "TGGenericPeerMediaGalleryImageItem.h"
#import "TGGenericPeerMediaGalleryVideoItem.h"

#import "TGGenericPeerMediaGalleryDefaultHeaderView.h"
#import "TGGenericPeerMediaGalleryDefaultFooterView.h"
#import "TGGenericPeerMediaGalleryActionsAccessoryView.h"
#import "TGGenericPeerMediaGalleryDeleteAccessoryView.h"

#import "TGStringUtils.h"
#import "TGActionSheet.h"

#import "ActionStage.h"

@interface TGGenericPeerMediaGalleryModel () <ASWatcher>
{
    ATQueue *_queue;
    
    NSArray *_modelItems;
    int32_t _atMessageId;
    
    NSUInteger _incompleteCount;
    bool _loadingCompleted;
    bool _loadingCompletedInternal;
}

@property (nonatomic, strong) ASHandle *actionHandle;

@end

@implementation TGGenericPeerMediaGalleryModel

- (instancetype)initWithPeerId:(int64_t)peerId atMessageId:(int32_t)atMessageId
{
    self = [super init];
    if (self != nil)
    {
        _actionHandle = [[ASHandle alloc] initWithDelegate:self];
        
        _queue = [[ATQueue alloc] init];
        
        _peerId = peerId;
        
        _atMessageId = atMessageId;
        [self _loadInitialItemsAtMessageId:_atMessageId];
            [NSString stringWithFormat:@"/tg/conversation/(%lld)/messages", _peerId],
            [NSString stringWithFormat:@"/tg/conversation/(%lld)/messagesChanged", _peerId],
            
        [ActionStageInstance() watchForPaths:@[
            [NSString stringWithFormat:@"/tg/conversation/(%lld)/messages", _peerId],
            [NSString stringWithFormat:@"/tg/conversation/(%lld)/messagesChanged", _peerId],
            [NSString stringWithFormat:@"/tg/conversation/(%lld)/messagesDeleted", _peerId]
        ] watcher:self];
    }
    return self;
}

- (void)dealloc
{
    [_actionHandle reset];
    [ActionStageInstance() removeWatcher:self];
}

- (void)_transitionCompleted
{
    [super _transitionCompleted];
    
    [_queue dispatch:^
    {
        NSArray *messages = [[TGDatabaseInstance() loadMediaInConversation:_peerId maxMid:INT_MAX maxLocalMid:INT_MAX maxDate:INT_MAX limit:INT_MAX count:NULL] sortedArrayUsingComparator:^NSComparisonResult(TGMessage *message1, TGMessage *message2)
        {
            NSTimeInterval date1 = message1.date;
            NSTimeInterval date2 = message2.date;
            
            if (ABS(date1 - date2) < DBL_EPSILON)
            {
                if (message1.mid > message2.mid)
                    return NSOrderedAscending;
                else
                    return NSOrderedDescending;
            }
            
            return date1 > date2 ? NSOrderedAscending : NSOrderedDescending;
        }];
        
        _loadingCompletedInternal = true;
        
        TGDispatchOnMainThread(^
        {
            _loadingCompleted = true;
        });
        
        [self _replaceMessages:messages atMessageId:_atMessageId];
    }];
    
    [ActionStageInstance() requestActor:[[NSString alloc] initWithFormat:@"/tg/updateMediaHistory/(%" PRIx64 ")", _peerId] options:@{@"peerId": @(_peerId)} flags:0 watcher:self];
}

- (void)_loadInitialItemsAtMessageId:(int32_t)atMessageId
{
    int count = 0;
    NSArray *messages = [[TGDatabaseInstance() loadMediaInConversation:_peerId atMessageId:atMessageId limitAfter:32 count:&count] sortedArrayUsingComparator:^NSComparisonResult(TGMessage *message1, TGMessage *message2)
    {
        NSTimeInterval date1 = message1.date;
        NSTimeInterval date2 = message2.date;
        
        if (ABS(date1 - date2) < DBL_EPSILON)
        {
            if (message1.mid > message2.mid)
                return NSOrderedAscending;
            else
                return NSOrderedDescending;
        }
        
        return date1 > date2 ? NSOrderedAscending : NSOrderedDescending;
    }];
    
    _incompleteCount = count;
    
    [self _replaceMessages:messages atMessageId:atMessageId];
}

- (void)_addMessages:(NSArray *)messages
{
    NSMutableArray *updatedModelItems = [[NSMutableArray alloc] initWithArray:_modelItems];
    
    NSMutableSet *currentMessageIds = [[NSMutableSet alloc] init];
    for (id<TGGenericPeerGalleryItem> item in updatedModelItems)
    {
        [currentMessageIds addObject:@([item messageId])];
    }
    
    for (TGMessage *message in messages)
    {
        if ([currentMessageIds containsObject:@(message.mid)])
            continue;
        
        for (id attachment in message.mediaAttachments)
        {
            if ([attachment isKindOfClass:[TGImageMediaAttachment class]])
            {
                TGImageMediaAttachment *imageMedia = attachment;
                
                NSString *legacyCacheUrl = [imageMedia.imageInfo closestImageUrlWithSize:CGSizeMake(1136, 1136) resultingSize:NULL pickLargest:true];
                
                int64_t localImageId = 0;
                if (imageMedia.imageId == 0 && legacyCacheUrl.length != 0)
                    localImageId = murMurHash32(legacyCacheUrl);
                
                TGGenericPeerMediaGalleryImageItem *imageItem = [[TGGenericPeerMediaGalleryImageItem alloc] initWithImageId:imageMedia.imageId orLocalId:localImageId peerId:_peerId messageId:message.mid legacyImageInfo:imageMedia.imageInfo];
                imageItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                imageItem.date = message.date;
                imageItem.messageId = message.mid;
                [updatedModelItems addObject:imageItem];
            }
            else if ([attachment isKindOfClass:[TGVideoMediaAttachment class]])
            {
                TGVideoMediaAttachment *videoMedia = attachment;
                TGGenericPeerMediaGalleryVideoItem *videoItem = [[TGGenericPeerMediaGalleryVideoItem alloc] initWithVideoMedia:videoMedia peerId:_peerId messageId:message.mid];
                videoItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                videoItem.date = message.date;
                videoItem.messageId = message.mid;
                [updatedModelItems addObject:videoItem];
            }
        }
    }
    
    [updatedModelItems sortUsingComparator:^NSComparisonResult(id<TGGenericPeerGalleryItem> item1, id<TGGenericPeerGalleryItem> item2)
    {
        NSTimeInterval date1 = [item1 date];
        NSTimeInterval date2 = [item2 date];
        
        if (ABS(date1 - date2) < DBL_EPSILON)
        {
            if ([item1 messageId] < [item2 messageId])
                return NSOrderedAscending;
            else
                return NSOrderedDescending;
        }
        
        return date1 < date2 ? NSOrderedAscending : NSOrderedDescending;
    }];
    
    _modelItems = updatedModelItems;
    
    [self _replaceItems:_modelItems focusingOnItem:nil];
}

- (void)_deleteMessagesWithIds:(NSArray *)messageIds
{
    NSMutableSet *messageIdsSet = [[NSMutableSet alloc] init];
    for (NSNumber *nMid in messageIds)
    {
        [messageIdsSet addObject:nMid];
    }
    
    NSMutableIndexSet *indexSet = [[NSMutableIndexSet alloc] init];
    NSInteger index = -1;
    for (id<TGGenericPeerGalleryItem> item in _modelItems)
    {
        index++;
        if ([messageIdsSet containsObject:@([item messageId])])
        {
            [indexSet addIndex:(NSUInteger)index];
        }
    }
    
    if (indexSet.count != 0)
    {
        NSMutableArray *updatedModelItems = [[NSMutableArray alloc] initWithArray:_modelItems];
        [updatedModelItems removeObjectsAtIndexes:indexSet];
        _modelItems = updatedModelItems;
        
        [self _replaceItems:_modelItems focusingOnItem:nil];
    }
}

- (void)_replaceMessagesWithNewMessages:(NSDictionary *)messagesById
{
    NSMutableArray *updatedModelItems = [[NSMutableArray alloc] initWithArray:_modelItems];
    
    bool changesFound = false;
    NSInteger index = -1;
    for (id<TGGenericPeerGalleryItem> item in updatedModelItems)
    {
        index++;
        
        if (messagesById[@([item messageId])] != nil)
        {
            TGMessage *message = messagesById[@([item messageId])];
            
            for (id attachment in message.mediaAttachments)
            {
                if ([attachment isKindOfClass:[TGImageMediaAttachment class]])
                {
                    TGImageMediaAttachment *imageMedia = attachment;
                    
                    NSString *legacyCacheUrl = [imageMedia.imageInfo closestImageUrlWithSize:CGSizeMake(1136, 1136) resultingSize:NULL pickLargest:true];
                    
                    int64_t localImageId = 0;
                    if (imageMedia.imageId == 0 && legacyCacheUrl.length != 0)
                        localImageId = murMurHash32(legacyCacheUrl);
                    
                    TGGenericPeerMediaGalleryImageItem *imageItem = [[TGGenericPeerMediaGalleryImageItem alloc] initWithImageId:imageMedia.imageId orLocalId:localImageId peerId:_peerId messageId:message.mid legacyImageInfo:imageMedia.imageInfo];
                    imageItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                    imageItem.date = message.date;
                    imageItem.messageId = message.mid;
                    
                    changesFound = true;
                    [updatedModelItems replaceObjectAtIndex:(NSUInteger)index withObject:imageItem];
                }
                else if ([attachment isKindOfClass:[TGVideoMediaAttachment class]])
                {
                    TGVideoMediaAttachment *videoMedia = attachment;
                    TGGenericPeerMediaGalleryVideoItem *videoItem = [[TGGenericPeerMediaGalleryVideoItem alloc] initWithVideoMedia:videoMedia peerId:_peerId messageId:message.mid];
                    videoItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                    videoItem.date = message.date;
                    videoItem.messageId = message.mid;

                    changesFound = true;
                    [updatedModelItems replaceObjectAtIndex:(NSUInteger)index withObject:videoItem];
                }
            }
        }
    }
    
    [updatedModelItems sortUsingComparator:^NSComparisonResult(id<TGGenericPeerGalleryItem> item1, id<TGGenericPeerGalleryItem> item2)
     {
         NSTimeInterval date1 = [item1 date];
         NSTimeInterval date2 = [item2 date];
         
         if (ABS(date1 - date2) < DBL_EPSILON)
         {
             if ([item1 messageId] < [item2 messageId])
                 return NSOrderedAscending;
             else
                 return NSOrderedDescending;
         }
         
         return date1 < date2 ? NSOrderedAscending : NSOrderedDescending;
     }];
    
    _modelItems = updatedModelItems;
    
    [self _replaceItems:_modelItems focusingOnItem:nil];
}

- (void)_replaceMessages:(NSArray *)messages atMessageId:(int32_t)atMessageId
{
    NSMutableArray *updatedModelItems = [[NSMutableArray alloc] init];
    
    id<TGModernGalleryItem> focusItem = nil;
    
    for (TGMessage *message in messages)
    {
        for (id attachment in message.mediaAttachments)
        {
            if ([attachment isKindOfClass:[TGImageMediaAttachment class]])
            {
                TGImageMediaAttachment *imageMedia = attachment;
                
                NSString *legacyCacheUrl = [imageMedia.imageInfo closestImageUrlWithSize:CGSizeMake(1136, 1136) resultingSize:NULL pickLargest:true];
                
                int64_t localImageId = 0;
                if (imageMedia.imageId == 0 && legacyCacheUrl.length != 0)
                    localImageId = murMurHash32(legacyCacheUrl);
                
                TGGenericPeerMediaGalleryImageItem *imageItem = [[TGGenericPeerMediaGalleryImageItem alloc] initWithImageId:imageMedia.imageId orLocalId:localImageId peerId:_peerId messageId:message.mid legacyImageInfo:imageMedia.imageInfo];
                imageItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                imageItem.date = message.date;
                imageItem.messageId = message.mid;
                [updatedModelItems insertObject:imageItem atIndex:0];
                
                if (atMessageId != 0 && atMessageId == message.mid)
                    focusItem = imageItem;
            }
            else if ([attachment isKindOfClass:[TGVideoMediaAttachment class]])
            {
                TGVideoMediaAttachment *videoMedia = attachment;
                TGGenericPeerMediaGalleryVideoItem *videoItem = [[TGGenericPeerMediaGalleryVideoItem alloc] initWithVideoMedia:videoMedia peerId:_peerId messageId:message.mid];
                videoItem.author = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
                videoItem.date = message.date;
                videoItem.messageId = message.mid;
                [updatedModelItems insertObject:videoItem atIndex:0];
                
                if (atMessageId != 0 && atMessageId == message.mid)
                    focusItem = videoItem;
            }
        }
    }
    
    _modelItems = updatedModelItems;
    
    [self _replaceItems:_modelItems focusingOnItem:focusItem];
}

- (UIView<TGModernGalleryDefaultHeaderView> *)createDefaultHeaderView
{
    __weak TGGenericPeerMediaGalleryModel *weakSelf = self;
    return [[TGGenericPeerMediaGalleryDefaultHeaderView alloc] initWithPositionAndCountBlock:^(id<TGModernGalleryItem> item, NSUInteger *position, NSUInteger *count)
    {
        __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
        if (strongSelf != nil)
        {
            if (position != NULL)
            {
                NSUInteger index = [strongSelf.items indexOfObject:item];
                if (index != NSNotFound)
                {
                    *position = strongSelf->_loadingCompleted ? index : (strongSelf->_incompleteCount - strongSelf.items.count + index);
                }
            }
            if (count != NULL)
                *count = strongSelf->_loadingCompleted ? strongSelf.items.count : strongSelf->_incompleteCount;
        }
    }];
}

- (UIView<TGModernGalleryDefaultFooterView> *)createDefaultFooterView
{
    return [[TGGenericPeerMediaGalleryDefaultFooterView alloc] init];
}

- (UIView<TGModernGalleryDefaultFooterAccessoryView> *)createDefaultLeftAccessoryView
{
    TGGenericPeerMediaGalleryActionsAccessoryView *accessoryView = [[TGGenericPeerMediaGalleryActionsAccessoryView alloc] init];
    __weak TGGenericPeerMediaGalleryModel *weakSelf = self;
    accessoryView.action = ^(id<TGModernGalleryItem> item)
    {
        if ([item conformsToProtocol:@protocol(TGGenericPeerGalleryItem)])
        {
            id<TGGenericPeerGalleryItem> concreteItem = (id<TGGenericPeerGalleryItem>)item;
            __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
            if (strongSelf != nil)
            {
                UIView *actionSheetView = nil;
                if (strongSelf.actionSheetView)
                    actionSheetView = strongSelf.actionSheetView();
                
                if (actionSheetView != nil)
                {
                    NSMutableArray *actions = [[NSMutableArray alloc] init];
                    
                    if (!TGAppDelegateInstance.autosavePhotos || [concreteItem author].uid == TGTelegraphInstance.clientUserId)
                    {
                        [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Preview.SaveToCameraRoll") action:@"save" type:TGActionSheetActionTypeGeneric]];
                    }
                    [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Preview.ForwardViaTelegram") action:@"forward" type:TGActionSheetActionTypeGeneric]];
                    [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Common.Cancel") action:@"cancel" type:TGActionSheetActionTypeCancel]];
                    
                    [[[TGActionSheet alloc] initWithTitle:nil actions:actions actionBlock:^(__unused id target, NSString *action)
                    {
                        __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
                        if ([action isEqualToString:@"save"])
                            [self _commitSaveItemToCameraRoll:item];
                        else if ([action isEqualToString:@"forward"])
                        {
                            
                        }
                    } target:strongSelf] showInView:actionSheetView];
                }
            }
        }
    };
    return accessoryView;
}

- (void)_commitSaveItemToCameraRoll:(id<TGModernGalleryItem>)item
{
    if ([item isKindOfClass:[TGGenericPeerMediaGalleryImageItem class]])
    {
        TGGenericPeerMediaGalleryImageItem *imageItem = (TGGenericPeerMediaGalleryImageItem *)item;
        
    }
    else if ([item isKindOfClass:[TGGenericPeerMediaGalleryVideoItem class]])
    {
        TGGenericPeerMediaGalleryVideoItem *videoItem = (TGGenericPeerMediaGalleryVideoItem *)item;
    }
}

- (UIView<TGModernGalleryDefaultFooterAccessoryView> *)createDefaultRightAccessoryView
{
    TGGenericPeerMediaGalleryDeleteAccessoryView *accessoryView = [[TGGenericPeerMediaGalleryDeleteAccessoryView alloc] init];
    __weak TGGenericPeerMediaGalleryModel *weakSelf = self;
    accessoryView.action = ^(id<TGModernGalleryItem> item)
    {
        __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
        if (strongSelf != nil)
        {
            UIView *actionSheetView = nil;
            if (strongSelf.actionSheetView)
                actionSheetView = strongSelf.actionSheetView();
            
            if (actionSheetView != nil)
            {
                NSMutableArray *actions = [[NSMutableArray alloc] init];
                
                NSString *actionTitle = nil;
                if ([item isKindOfClass:[TGModernGalleryImageItem class]])
                    actionTitle = TGLocalized(@"Preview.DeletePhoto");
                else
                    actionTitle = TGLocalized(@"Preview.DeleteVideo");
                [actions addObject:[[TGActionSheetAction alloc] initWithTitle:actionTitle action:@"delete" type:TGActionSheetActionTypeDestructive]];
                [actions addObject:[[TGActionSheetAction alloc] initWithTitle:TGLocalized(@"Common.Cancel") action:@"cancel" type:TGActionSheetActionTypeCancel]];
                
                [[[TGActionSheet alloc] initWithTitle:nil actions:actions actionBlock:^(__unused id target, NSString *action)
                {
                    __strong TGGenericPeerMediaGalleryModel *strongSelf = weakSelf;
                    if ([action isEqualToString:@"delete"])
                    {
                        [strongSelf _commitDeleteItem:item];
                    }
                } target:strongSelf] showInView:actionSheetView];
            }
        }
    };
    return accessoryView;
}

- (void)_commitDeleteItem:(id<TGModernGalleryItem>)item
{
    [_queue dispatch:^
    {
        if ([item conformsToProtocol:@protocol(TGGenericPeerGalleryItem)])
        {
            id<TGGenericPeerGalleryItem> concreteItem = (id<TGGenericPeerGalleryItem>)item;
            
            NSArray *messageIds = @[@([concreteItem messageId])];
            [self _deleteMessagesWithIds:messageIds];
            static int actionId = 1;
            [ActionStageInstance() requestActor:[NSString stringWithFormat:@"/tg/conversation/(%lld)/deleteMessages/(genericPeerMedia%d)", _peerId, actionId++] options:@{@"mids": messageIds} watcher:TGTelegraphInstance];
        }
    }];
}

- (void)actionStageResourceDispatched:(NSString *)path resource:(id)resource arguments:(id)__unused arguments
{
    if ([path isEqualToString:[[NSString alloc] initWithFormat:@"/tg/conversation/(%lld)/messages", _peerId]])
    {
        [_queue dispatch:^
        {
            if (!_loadingCompletedInternal)
                return;
            
            NSArray *messages = [((SGraphObjectNode *)resource).object mutableCopy];
            [self _addMessages:messages];
        }];
    }
    else if ([path isEqualToString:[[NSString alloc] initWithFormat:@"/tg/conversation/(%lld)/messagesChanged", _peerId]])
    {
        [_queue dispatch:^
        {
            NSArray *midMessagePairs = ((SGraphObjectNode *)resource).object;
            NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
            for (NSUInteger i = 0; i < midMessagePairs.count; i += 2)
            {
                dict[midMessagePairs[0]] = midMessagePairs[1];
            }
            
            [self _replaceMessagesWithNewMessages:dict];
        }];
    }
    else if ([path isEqualToString:[[NSString alloc] initWithFormat:@"/tg/conversation/(%lld)/messagesDeleted", _peerId]])
    {
        [_queue dispatch:^
        {
            [self _deleteMessagesWithIds:((SGraphObjectNode *)resource).object];
        }];
    }
}

- (void)actorMessageReceived:(NSString *)path messageType:(NSString *)messageType message:(id)message
{
    if ([path isEqualToString:[[NSString alloc] initWithFormat:@"/tg/updateMediaHistory/(%" PRIx64 ")", _peerId]])
    {
        if ([messageType isEqualToString:@"messagesLoaded"])
        {
            [_queue dispatch:^
            {
                [self _addMessages:message];
            }];
        }
    }
}

@end