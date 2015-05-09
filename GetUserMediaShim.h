//
//  GetUserMedia.h
//  CommonTater
//
//  Created by Jesse Tane on 5/4/15.
//  Copyright (c) 2015 Common Tater. All rights reserved.
//

#ifndef CommonTater_GetUserMedia_h
#define CommonTater_GetUserMedia_h

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <AudioToolbox/AudioToolbox.h>

@interface GetUserMedia : NSObject <WKScriptMessageHandler> {
  NSArray *methods;
  NSMutableDictionary *tracks;
  BOOL audioStarted;
  BOOL videoStarted;
}

@property (nonatomic, assign) WKWebView *webView;
@property (nonatomic) AudioComponentInstance audioUnit;

@property (nonatomic) AudioBuffer audioBuffer;
@property (nonatomic) AudioBufferList audioBufferList;
@property (nonatomic) NSMutableData *audioData;

@property (nonatomic) NSMutableData *videoBuffer;

- (id)initWithWebView:(WKWebView*)view contentController:(WKUserContentController *)controller;

- (void) MediaStream_new:(NSDictionary*)params;
- (void) MediaStreamTrack_stop:(NSDictionary*)params;

- (NSString*) startAudio;
- (void) onaudio;
- (void) stopAudio;

- (NSString*) startVideo;
- (void) onvideo;
- (void) stopVideo;

@end

#endif
