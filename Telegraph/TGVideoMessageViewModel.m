#import "TGVideoMessageViewModel.h"

#import <LegacyComponents/LegacyComponents.h>

#import "TGTelegraphConversationMessageAssetsSource.h"

#import "TGModernImageViewModel.h"
#import "TGMessageImageViewModel.h"
#import "TGModernRemoteImageViewModel.h"
#import "TGModernFlatteningViewModel.h"
#import "TGModernLabelViewModel.h"
#import "TGModernTextViewModel.h"

#import "TGModernRemoteImageView.h"
#import "TGModernRemoteImageViewModel.h"
#import "TGModernColorViewModel.h"
#import "TGInstantPreviewTouchAreaModel.h"
#import "TGModernButtonViewModel.h"

#import "TGReusableLabel.h"

#import "TGMessageImageView.h"

#import "TGAppDelegate.h"

#import "TGMessageGroupedLayout.h"

@interface TGVideoMessageViewModel ()
{
    TGVideoMediaAttachment *_video;
    int _videoSize;
    
    bool _progressVisible;
    
    CGPoint _boundOffset;
}

@end

@implementation TGVideoMessageViewModel

+ (NSString *)filePathForVideoId:(int64_t)videoId local:(bool)local
{
    static NSString *videosDirectory = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        NSString *documentsDirectory = [TGAppDelegate documentsPath];
        videosDirectory = [documentsDirectory stringByAppendingPathComponent:@"video"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:videosDirectory])
            [[NSFileManager defaultManager] createDirectoryAtPath:videosDirectory withIntermediateDirectories:true attributes:nil error:nil];
    });
    
    return [videosDirectory stringByAppendingPathComponent:[[NSString alloc] initWithFormat:@"%@%" PRIx64 ".mov", local ? @"local" : @"remote", videoId]];
}

- (instancetype)initWithMessage:(TGMessage *)message imageInfo:(TGImageInfo *)imageInfo video:(TGVideoMediaAttachment *)video authorPeer:(id)authorPeer context:(TGModernViewContext *)context forwardPeer:(id)forwardPeer forwardAuthor:(id)forwardAuthor forwardMessageId:(int32_t)forwardMessageId replyHeader:(TGMessage *)replyHeader replyAuthor:(id)replyAuthor viaUser:(TGUser *)viaUser webPage:(TGWebPageMediaAttachment *)webPage
{
    TGImageInfo *previewImageInfo = imageInfo;
    
    NSString *legacyVideoFilePath = [TGVideoMessageViewModel filePathForVideoId:video.videoId != 0 ? video.videoId : video.localVideoId local:video.videoId == 0];
    NSString *legacyThumbnailCacheUri = [imageInfo closestImageUrlWithSize:CGSizeZero resultingSize:NULL];
    
    if (video.videoId != 0 || video.localVideoId != 0)
    {
        previewImageInfo = [[TGImageInfo alloc] init];
        
        NSMutableString *previewUri = [[NSMutableString alloc] initWithString:@"video-thumbnail://?"];
        if (video.videoId != 0)
        {
            [previewUri appendFormat:@"id=%" PRId64 "", video.videoId];
            [previewUri appendFormat:@"&cid=%" PRId64 "", message.cid];
            [previewUri appendFormat:@"&mid=%" PRId32 "", message.mid];
            
            if (video.originInfo != nil)
                [previewUri appendFormat:@"&origin_info=%@", [video.originInfo stringRepresentation]];
        }
        else
            [previewUri appendFormat:@"local-id=%" PRId64 "", video.localVideoId];
        
        CGSize thumbnailSize = CGSizeZero;
        CGSize renderSize = CGSizeZero;
        [TGImageMessageViewModel calculateImageSizesForImageSize:video.dimensions thumbnailSize:&thumbnailSize renderSize:&renderSize squareAspect:message.messageLifetime > 0 && message.messageLifetime <= 60 && message.layer >= 17];
        
        [previewUri appendFormat:@"&width=%d&height=%d&renderWidth=%d&renderHeight=%d", (int)thumbnailSize.width, (int)thumbnailSize.height, (int)renderSize.width, (int)renderSize.height];
     
        if (_positionFlags != 0)
            [previewUri appendFormat:@"&position=%d", _positionFlags];
        
        [previewUri appendFormat:@"&legacy-video-file-path=%@", legacyVideoFilePath];
        if (legacyThumbnailCacheUri != nil)
            [previewUri appendFormat:@"&legacy-thumbnail-cache-url=%@", legacyThumbnailCacheUri];
        
        if (message.messageLifetime > 0 && message.messageLifetime <= 60 && message.layer >= 17)
            [previewUri appendString:@"&secret=1"];
        
        [previewImageInfo addImageWithSize:renderSize url:previewUri];
    }
    
    self = [super initWithMessage:message imageInfo:previewImageInfo authorPeer:authorPeer context:context forwardPeer:forwardPeer forwardAuthor:forwardAuthor forwardMessageId:forwardMessageId replyHeader:replyHeader replyAuthor:replyAuthor viaUser:viaUser caption:message.caption textCheckingResults:message.textCheckingResults webPage:webPage];
    if (self != nil)
    {
        _video = video;
        [_video.videoInfo urlWithQuality:0 actualQuality:NULL actualSize:&_videoSize];
        
        if (message.messageLifetime > 0 && message.messageLifetime <= 60 && message.layer >= 17)
        {
            self.isSecret = true;
            
            //[self enableInstantPreview];
        }
        
        int minutes = video.duration / 60;
        int seconds = video.duration % 60;
        
        if (self.isSecret)
            [self.imageModel setAdditionalDataString:[self defaultAdditionalDataString]];
        else
            [self.imageModel setAdditionalDataString:[[NSString alloc] initWithFormat:@"%d:%02d", minutes, seconds]];
    }
    return self;
}

- (NSString *)updatedImageUriForMessage:(TGMessage *)message outImageInfo:(TGImageInfo **)outImageInfo
{
    TGVideoMediaAttachment *video = nil;
    for (id attachment in message.mediaAttachments)
    {
        if ([attachment isKindOfClass:[TGVideoMediaAttachment class]])
        {
            video = attachment;
            break;
        }
    }
    
    TGImageInfo *previewImageInfo = video.thumbnailInfo;
    
    CGSize largestSize = CGSizeZero;
    NSString *legacyVideoFilePath = [TGVideoMessageViewModel filePathForVideoId:video.videoId != 0 ? video.videoId : video.localVideoId local:video.videoId == 0];
    NSString *legacyThumbnailCacheUri = [previewImageInfo closestImageUrlWithSize:CGSizeZero resultingSize:&largestSize];
    
    if (video.videoId != 0 || video.localVideoId != 0)
    {
        previewImageInfo = [[TGImageInfo alloc] init];
        
        NSMutableString *previewUri = [[NSMutableString alloc] initWithString:@"video-thumbnail://?"];
        if (video.videoId != 0)
        {
            [previewUri appendFormat:@"id=%" PRId64 "", video.videoId];
            
            [previewUri appendFormat:@"&cid=%" PRId64 "", message.cid];
            [previewUri appendFormat:@"&mid=%" PRId32 "", message.mid];
            
            if (video.originInfo != nil)
                [previewUri appendFormat:@"&origin_info=%@", [video.originInfo stringRepresentation]];
        }
        else
            [previewUri appendFormat:@"local-id=%" PRId64 "", video.localVideoId];
        
        CGSize thumbnailSize = CGSizeZero;
        CGSize renderSize = CGSizeZero;
        
        if (self.groupedLayout != nil)
        {
            CGRect frame = [self.groupedLayout frameForMessageId:message.mid];
            thumbnailSize = frame.size;
            renderSize = TGScaleToFill(largestSize, thumbnailSize);
        }
        else
        {
            [TGImageMessageViewModel calculateImageSizesForImageSize:video.dimensions thumbnailSize:&thumbnailSize renderSize:&renderSize squareAspect:message.messageLifetime > 0 && message.messageLifetime <= 60 && message.layer >= 17];
        }
        
        [previewUri appendFormat:@"&width=%d&height=%d&renderWidth=%d&renderHeight=%d", (int)thumbnailSize.width, (int)thumbnailSize.height, (int)renderSize.width, (int)renderSize.height];
            
        [previewUri appendFormat:@"&legacy-video-file-path=%@", legacyVideoFilePath];
        if (legacyThumbnailCacheUri != nil)
            [previewUri appendFormat:@"&legacy-thumbnail-cache-url=%@", legacyThumbnailCacheUri];
        
        if (message.messageLifetime > 0 && message.messageLifetime <= 60 && message.layer >= 17)
            [previewUri appendString:@"&secret=1"];
        
        [previewImageInfo addImageWithSize:renderSize url:previewUri];
        
        if (outImageInfo != NULL)
            *outImageInfo = previewImageInfo;
        
        return [self updatedImageUriForInfo:previewImageInfo];
    }
    return nil;
}

- (void)updateMessage:(TGMessage *)message viewStorage:(TGModernViewStorage *)viewStorage sizeUpdated:(bool *)sizeUpdated
{
    [super updateMessage:message viewStorage:viewStorage sizeUpdated:sizeUpdated];
    
    TGVideoMediaAttachment *video = nil;
    
    for (TGMediaAttachment *attachment in message.mediaAttachments)
    {
        if ([attachment isKindOfClass:[TGVideoMediaAttachment class]])
        {
            video = (TGVideoMediaAttachment *)attachment;
            break;
        }
    }
    
    if (video == nil)
        return;
    
    _video = video;
    [_video.videoInfo urlWithQuality:0 actualQuality:NULL actualSize:&_videoSize];
}

- (void)updateProgress:(bool)progressVisible progress:(float)progress viewStorage:(TGModernViewStorage *)viewStorage animated:(bool)animated
{
    [super updateProgress:progressVisible progress:progress viewStorage:viewStorage animated:animated];
    
    _progressVisible = progressVisible;
    
    NSString *labelText = nil;
    
    if (progressVisible)
    {
        if (_videoSize == INT_MAX)
        {
            labelText = TGLocalized(@"Conversation.Processing");
        }
        else if (_videoSize < 1024 * 1024)
        {
            labelText = [[NSString alloc] initWithFormat:@"%1$d KB / %2$d KB", (int)(_videoSize * progress / 1024), (int)(_videoSize / 1024)];
        }
        else
        {
            labelText = [[NSString alloc] initWithFormat:TGLocalized(@"%.02f MB / %.02f MB"), ((float)_videoSize * progress / (1024 * 1024)), ((float)_videoSize / (1024 * 1024))];
        }
    }
    else
    {
        if (self.isSecret)
            labelText = [self defaultAdditionalDataString];
        else
        {
            int minutes = _video.duration / 60;
            int seconds = _video.duration % 60;
            labelText = [[NSString alloc] initWithFormat:@"%d:%02d", minutes, seconds];
        }
    }
    
    if (_positionFlags == TGMessageGroupPositionNone)
        [self.imageModel setAdditionalDataString:labelText];
    else
        [self.imageModel setAdditionalDataString:nil];
}

- (void)setPositionFlags:(int)positionFlags
{
    [super setPositionFlags:positionFlags];
    
    if (_positionFlags != TGMessageGroupPositionNone)
        [self.imageModel setAdditionalDataString:nil];
}

- (bool)instantPreviewGesture
{
    return false;
}

- (bool)isPreviewableAtPoint:(CGPoint)point
{
    if (self.isSecret)
        return false;
    
    return CGRectContainsPoint(self.imageModel.frame, point);
}

- (void)bindSpecialViewsToContainer:(UIView *)container viewStorage:(TGModernViewStorage *)viewStorage atItemPosition:(CGPoint)itemPosition
{
    _boundOffset = itemPosition;
    
    [super bindSpecialViewsToContainer:container viewStorage:viewStorage atItemPosition:itemPosition];
}

- (void)bindViewToContainer:(UIView *)container viewStorage:(TGModernViewStorage *)viewStorage
{
    _boundOffset = CGPointZero;
    
    [super bindViewToContainer:container viewStorage:viewStorage];
}

- (void)layoutForContainerSize:(CGSize)containerSize
{
    [super layoutForContainerSize:containerSize];
}

- (int)defaultOverlayActionType
{
    if (self.isSecret)
        return [super defaultOverlayActionType];
    
    return TGMessageImageViewOverlayPlay;
}

- (bool)isInstant {
    return self.isSecret;
}

@end
