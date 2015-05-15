//
//  WKWebViewGetUserMediaShim.m
//  CommonTater
//
//  Created by Jesse Tane on 5/4/15.
//  Copyright (c) 2015 Common Tater. All rights reserved.
//

#import "WKWebViewGetUserMediaShim.h"

//#define WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG 1
#define WKWEBVIEW_GET_USER_MEDIA_SHIM_BYTES_PER_FRAME 4
#define WKWEBVIEW_GET_USER_MEDIA_SHIM_MIN_BYTES (WKWEBVIEW_GET_USER_MEDIA_SHIM_BYTES_PER_FRAME * 4096)

static OSStatus recordingCallback(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
  WKWebViewGetUserMediaShim *target = (__bridge WKWebViewGetUserMediaShim*)inRefCon;
  AudioBufferList bufferList = target.audioBufferList;
  OSStatus status = AudioUnitRender(target.audioUnit,
                           ioActionFlags,
                           inTimeStamp,
                           inBusNumber,
                           inNumberFrames,
                           &bufferList);

  if (status) {
    [NSException raise:@"Error" format:@"#%d: failed to render audio data to buffer", (int)status];
  }

#ifdef WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG
  NSLog(@"recording callback was called with %d frames", (unsigned int)inNumberFrames);
#endif

  NSUInteger inNumberBytes = inNumberFrames * WKWEBVIEW_GET_USER_MEDIA_SHIM_BYTES_PER_FRAME;
  [target.audioData appendBytes:target.audioBuffer.mData length:inNumberBytes];

  if (target.audioData.length >= WKWEBVIEW_GET_USER_MEDIA_SHIM_MIN_BYTES) {
    @autoreleasepool { [target onaudio]; }
    [target.audioData setLength:0];
  }
  
  return noErr;
}


@implementation WKWebViewGetUserMediaShim

@synthesize webView,
            audioUnit,
            audioBuffer,
            audioBufferList,
            audioData,
            videoBuffer;

- (id) initWithWebView:(WKWebView*)view
     contentController:(WKUserContentController *)controller {

  if (self = [super init]) {
    webView = view;
    tracks = [[NSMutableDictionary alloc] init];

    audioStarted = NO;

    audioBuffer.mDataByteSize = WKWEBVIEW_GET_USER_MEDIA_SHIM_MIN_BYTES;
    audioBuffer.mData = malloc(WKWEBVIEW_GET_USER_MEDIA_SHIM_MIN_BYTES);
    audioBuffer.mNumberChannels = 1;
    audioBufferList.mNumberBuffers = 1;
    audioBufferList.mBuffers[0] = audioBuffer;
    audioData = [[NSMutableData alloc] init];
    
    videoStarted = NO;

    methods = @[
      @"WKWebViewGetUserMediaShim_MediaStream_new",
      @"WKWebViewGetUserMediaShim_MediaStreamTrack_stop",
    ];

    for (NSString *method in methods) {
      [controller addScriptMessageHandler:self name:method];
    }

    NSString * path = [[NSBundle mainBundle].resourcePath stringByAppendingString:@"/WKWebViewGetUserMediaShim.js"];
    NSString * bindingJs = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    WKUserScript * script = [[WKUserScript alloc] initWithSource:bindingJs injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [controller addUserScript:script];

#ifdef WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG
  NSLog(@"did create getUserMedia shim");
#endif
  }

  return self;
}

#pragma mark incoming JavaScript message

- (void) userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
  NSDictionary * params = (NSDictionary *) message.body;
  NSString *name = nil;

  for (NSString *method in methods) {
    if ([message.name isEqualToString:method]) {
      name = [[method componentsSeparatedByString:@"WKWebViewGetUserMediaShim_"] objectAtIndex:1];
      name = [name stringByAppendingString:@":"];
      break;
    }
  }

  if (name == nil) {

#ifdef WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG
  NSLog(@"unrecognized method");
#endif

    return;
  }

  // ridiculous hoop jumping to call method by name
  SEL selector = NSSelectorFromString(name);
  IMP imp = [self methodForSelector:selector];
  void (*func)(id, SEL, NSDictionary *) = (void *)imp;
  func(self, selector, params);

  // lame hack to fix over-retained message.body
  CFRelease((__bridge CFTypeRef) params);
}


#pragma mark public

- (void) MediaStream_new:(NSDictionary*)params {

#ifdef WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG
  NSLog(@"MediaStream_new: %@", params);
#endif

  BOOL audio = [params[@"audio"] boolValue];
  BOOL video = [params[@"video"] boolValue];
  NSString *onsuccess = params[@"onsuccess"];
  NSString *onerror = params[@"onerror"];

  NSMutableArray *streamTracks = [[NSMutableArray alloc] init];
  NSString *trackId;
  NSString *error;
  NSString *json;
  NSString *js;

  if (!video && !audio) {
    js = [NSString stringWithFormat:@"window.navigator.getUserMedia._callbacks['%@']([])", onsuccess ];
    [webView evaluateJavaScript:js completionHandler:nil];
    return;
  } else if (video) {
    js = [NSString stringWithFormat:@"window.navigator.getUserMedia._callbacks['%@'](new Error('video is not yet supported'))", onerror ];
    [webView evaluateJavaScript:js completionHandler:nil];
    return;
  } else if (audio) {
    trackId = [self genUniqueId:tracks];
    NSDictionary *trackData = @{
      @"id": trackId,
      @"kind": @"audio",
      @"meta": @{
        @"bitDepth": [NSNumber numberWithInt:32],
        @"sampleRate": [NSNumber numberWithFloat:44100.0],
        @"channelCount": [NSNumber numberWithInt:1]
      }
    };
    [tracks setValue:trackData forKey:trackId];
    [streamTracks addObject:trackData];
  }

  if (audio && !audioStarted) {
    error = [self startAudio];
    if (error) {
      js = [NSString stringWithFormat:@"window.navigator.getUserMedia._callbacks['%@'](new Error('%@'))", onerror, error ];
      [webView evaluateJavaScript:js completionHandler:nil];
      return;
    }
  }

  json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:streamTracks options:0 error:nil] encoding:NSUTF8StringEncoding];
  js = [NSString stringWithFormat:@"window.navigator.getUserMedia._callbacks['%@'](%@)", onsuccess, json ];
  [webView evaluateJavaScript:js completionHandler:nil];
}

- (void) MediaStreamTrack_stop:(NSDictionary*)params {

#ifdef WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG
  NSLog(@"MediaStreamTrack_stop: %@", params);
#endif

  NSString *trackId = params[@"id"];
  NSDictionary *trackData = tracks[trackId];
  int audioTrackCount = 0;
  int videoTrackCount = 0;

  if (!trackData) {
    [NSException raise:@"Error" format:@"MediaStreamTrack with id %@ was not found", trackId];
  }

  [tracks removeObjectForKey:trackId];

  for (trackData in tracks) {
    if ([trackData[@"kind"] isEqualToString:@"audio"]) {
      audioTrackCount++;
    } else if ([trackData[@"kind"] isEqualToString:@"video"]) {
      videoTrackCount++;
    }
  }

  if (audioTrackCount == 0 && audioStarted) {
    [self stopAudio];
  }
  
  if (videoTrackCount == 0 && videoStarted) {
    [self stopVideo];
  }
}


#pragma mark audio capture

- (NSString*) startAudio {
  OSStatus status;
  UInt32 flag = 1;
  
  // find mic component and use it to create an audio unit
  AudioComponentDescription componentDescription;
  componentDescription.componentType = kAudioUnitType_Output;
  componentDescription.componentSubType = kAudioUnitSubType_RemoteIO;
  componentDescription.componentFlags = 0;
  componentDescription.componentFlagsMask = 0;
  componentDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
  
  AudioComponent component = AudioComponentFindNext(NULL, &componentDescription);
  status = AudioComponentInstanceNew(component, &audioUnit);
  
  if (status) {
    return [NSString stringWithFormat:@"#%d: failed to create audio unit", (int)status];
  }
  
  // indicate that we want to capture from the input bus
  status = AudioUnitSetProperty(audioUnit,
                                kAudioOutputUnitProperty_EnableIO,
                                kAudioUnitScope_Input,
                                1,
                                &flag,
                                sizeof(flag));

  if (status) {
    return [NSString stringWithFormat:@"#%d: failed to configure audio unit", (int)status];
  }

  // describe capture format
  AudioStreamBasicDescription format;
  format.mSampleRate	= 44100.0;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
  format.mFramesPerPacket = 1;
  format.mBitsPerChannel = 32;
  format.mChannelsPerFrame	= 1;
  format.mBytesPerFrame = format.mBitsPerChannel >> 3;
  format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket * format.mChannelsPerFrame;

  status = AudioUnitSetProperty(audioUnit,
                                kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Output,
                                1,
                                &format,
                                sizeof(format));

  if (status) {
    return [NSString stringWithFormat:@"#%d: failed to set capture format", (int)status];
  }

  // set recording callback on the input bus
  AURenderCallbackStruct callbackStruct;
  callbackStruct.inputProc = recordingCallback;
  callbackStruct.inputProcRefCon = (__bridge void *)(self);

  status = AudioUnitSetProperty(audioUnit,
                                kAudioOutputUnitProperty_SetInputCallback,
                                kAudioUnitScope_Global,
                                1,
                                &callbackStruct,
                                sizeof(callbackStruct));

  if (status) {
    return [NSString stringWithFormat:@"#%d: failed to set recording callback", (int)status];
  }

  status = AudioUnitInitialize(audioUnit);
  if (status) {
    return [NSString stringWithFormat:@"#%d: failed to initialize audio unit", (int)status];
  }

  status = AudioOutputUnitStart(audioUnit);
  if (status) {
    return [NSString stringWithFormat:@"#%d: failed to start capturing audio", (int)status];
  }

  audioStarted = YES;

#ifdef WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG
  NSLog(@"did start capturing audio");
#endif

  return nil;
}

- (void) stopAudio {
  OSStatus status = AudioOutputUnitStop(audioUnit);
  if (status) {
    [NSException raise:@"Error" format:@"#%d: failed to stop capturing audio", (int)status];
  }

  status = AudioUnitUninitialize(audioUnit);
  if (status) {
    [NSException raise:@"Error" format:@"#%d: failed to uninitialize audio unit", (int)status];
  }

  status = AudioComponentInstanceDispose(audioUnit);
  if (status) {
    [NSException raise:@"Error" format:@"#%d: failed to dispose audio unit", (int)status];
  }

  audioUnit = nil;
  audioStarted = NO;

#ifdef WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG
  NSLog(@"did stop capturing audio");
#endif
}


#pragma mark video capture

- (NSString*) startVideo {
  [NSException raise:@"Error" format:@"video is not implemented yet"];
  return nil;
}

- (void) stopVideo {
  [NSException raise:@"Error" format:@"video is not implemented yet"];
  videoStarted = NO;
}

- (void) onaudio {

#ifdef WKWEBVIEW_GET_USER_MEDIA_SHIM_DEBUG
  NSLog(@"onaudio %lu", (unsigned long) audioData.length);
#endif

  NSString *binaryString = [audioData base64EncodedStringWithOptions:0];
  NSString *js = [NSString stringWithFormat:@"window.navigator.getUserMedia._onmedia('audio', '%@')", binaryString ];
  [webView evaluateJavaScript:js completionHandler:nil];
}

- (void) onvideo {
  // TODO
}


#pragma mark Helpers

- (NSString*) genUniqueId:(NSDictionary *)lookup {
  NSString *uid = [self genId];
  while ([lookup objectForKey:uid]) {
    uid = [self genId];
  }
  return uid;
}

- (NSString*) genId {
  NSMutableString* string = [NSMutableString stringWithCapacity:16];
  for (int i = 0; i < 16; i++) {
    [string appendFormat:@"%C", (unichar)('a' + arc4random_uniform(25))];
  }
  return string;
}

@end
