//
//  ViewController.m
//  AudioQueueSample
//
//  Created by Shohei Sugawa on 2016/05/23.
//  Copyright © 2016年 Shohei.Sugawa. All rights reserved.
//

#import "ViewController.h"

typedef NS_ENUM(NSUInteger, AudioQueueState) {
    AudioQueueState_Idle,
    AudioQueueState_Recording,
    AudioQueueState_Playing,
};

@import AVFoundation;

@interface ViewController ()

@property AudioQueueState currentState;
@property (strong, nonatomic) NSURL *audioFileURL;

@property (weak, nonatomic) IBOutlet UIButton *recButton;
@property (weak, nonatomic) IBOutlet UIButton *playButton;

- (IBAction)recButtonTapped:(id)sender;
- (IBAction)playButtonTapped:(id)sender;
@end

#define NUM_BUFFERS 10

static SInt64 currentByte;
static AudioStreamBasicDescription audioFormat;
static AudioQueueRef queue;
static AudioQueueBufferRef buffers[NUM_BUFFERS];
static AudioFileID audioFileID;

@implementation ViewController

#pragma mark - Callback
void AudioOutputCallback(void *inUserData,
                         AudioQueueRef outAQ,
                         AudioQueueBufferRef outBuffer) {
    ViewController *viewController = (__bridge ViewController*)inUserData;
    
    if (viewController.currentState != AudioQueueState_Playing) {
        return;
    }
    
    UInt32 numBytes = 16000;
    OSStatus status = AudioFileReadBytes(audioFileID,
                                         false,
                                         currentByte,
                                         &numBytes,
                                         outBuffer->mAudioData);
    if (status != noErr && status != kAudioFileEndOfFileError) {
        printf("Error\n");
        return;
    }
    
    if (numBytes > 0) {
        outBuffer->mAudioDataByteSize = numBytes;
        OSStatus statusOfEnqueue = AudioQueueEnqueueBuffer(queue,
                                         outBuffer,
                                         0,
                                         NULL);
        if (statusOfEnqueue != noErr) {
            printf("Error\n");
            return;
        }
        
        currentByte += numBytes;
    }
    
    if (numBytes == 0 || status == kAudioFileEndOfFileError) {
        AudioQueueStop(queue, false);
        AudioFileClose(audioFileID);
        viewController.currentState = AudioQueueState_Idle;
    }
    
}

void AudioInputCallback(
                        void *inUserData,
                        AudioQueueRef inAQ,
                        AudioQueueBufferRef inBuffer,
                        const AudioTimeStamp *inStartTime,
                        UInt32 inNumberPacketDescriptions,
                        const AudioStreamPacketDescription *inPacketDescs
                        ) {
    ViewController *viewController = (__bridge ViewController*)inUserData;
    
    if (viewController.currentState != AudioQueueState_Recording) {
        return;
    }
    
    UInt32 ioBytes = audioFormat.mBytesPerPacket * inNumberPacketDescriptions;
    OSStatus status = AudioFileWriteBytes(audioFileID,
                                          false,
                                          currentByte,
                                          &ioBytes,
                                          inBuffer->mAudioData);
    if (status != noErr) {
        printf("Error");
        return;
    }
    
    currentByte += ioBytes;
    status = AudioQueueEnqueueBuffer(queue, inBuffer, 0, NULL);
    printf("HERE\n");
}

#pragma mark - View Lifecycle
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    [self setupAudio];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - Audio Setup
- (void)setupAudio {
    audioFormat.mSampleRate = 44100.00;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mChannelsPerFrame = 1;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mBytesPerFrame = audioFormat.mChannelsPerFrame * sizeof(SInt16);
    audioFormat.mBytesPerPacket = audioFormat.mFramesPerPacket * audioFormat.mBytesPerFrame;
    
    self.currentState = AudioQueueState_Idle;
}

# pragma mark - Switch Button Title
//- (void)switchRecButtonTitle {
//    if (self.currentState == AudioQueueState_Recording) {
//        [self.recButton setTitle:@"STOP" forState:UIControlStateNormal];
//    } else {
//        [self.recButton setTitle:@"REC" forState:UIControlStateNormal];
//    }
//}
//
//- (void)switchPlayButtonTitle {
//    if (self.currentState == AudioQueueState_Playing) {
//        [self.playButton setTitle:@"STOP" forState:UIControlStateNormal];
//    } else {
//        [self.playButton setTitle:@"PLAY" forState:UIControlStateNormal];
//    }
//}

- (void)stopRecording {
    self.currentState = AudioQueueState_Idle;
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueFreeBuffer(queue, buffers[i]);
    }
    AudioQueueDispose(queue, true);
    AudioFileClose(audioFileID);
}

- (IBAction)recButtonTapped:(id)sender {
    switch (self.currentState) {
        case AudioQueueState_Idle:
            break;
        case AudioQueueState_Playing:
            return;
        case AudioQueueState_Recording:
            [self stopRecording];
            return;
        default:
            break;
    }
    
    NSError *error;
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    NSAssert(error == nil, @"Error");
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:&error];
    NSAssert(error == nil, @"Error");
    
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        if (granted) {
            self.currentState = AudioQueueState_Recording;
            currentByte = 0;
            
            OSStatus status;
            status = AudioQueueNewInput(&audioFormat,
                                        AudioInputCallback, (__bridge void*)self,
                                        CFRunLoopGetCurrent(),
                                        kCFRunLoopCommonModes,
                                        0,
                                        &queue);
            NSAssert(status == noErr, @"Error");
            
            for (int i = 0; i < NUM_BUFFERS; i++) {
                status = AudioQueueAllocateBuffer(queue, 16000, &buffers[i]);
                NSAssert(status == noErr, @"Error");
                status = AudioQueueEnqueueBuffer(queue, buffers[i], 0, NULL);
                NSAssert(status == noErr, @"Error");
            }
            
            NSString *directoryName = NSTemporaryDirectory();
            NSString *fileName = [directoryName stringByAppendingPathComponent:@"audioQueueFile.wav"];
            self.audioFileURL = [NSURL URLWithString:fileName];
            
            status = AudioFileCreateWithURL((__bridge CFURLRef)self.audioFileURL,
                                            kAudioFileWAVEType,
                                            &audioFormat,
                                            kAudioFileFlags_EraseFile,
                                            &audioFileID);
            NSAssert(status == noErr, @"Error");
            
            status = AudioQueueStart(queue, NULL);
            NSAssert(status == noErr, @"Error");
            
        } else {
            NSAssert(error == nil, @"Error");
        }
    }];

}

- (void)stopPlayback {
    self.currentState = AudioQueueState_Idle;
    AudioQueueStop(queue, true);
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueFreeBuffer(queue, buffers[i]);
    }
    AudioQueueDispose(queue, true);
    AudioFileClose(audioFileID);
}

- (IBAction)playButtonTapped:(id)sender {
    switch (self.currentState) {
        case AudioQueueState_Idle:
            break;
        case AudioQueueState_Playing:
            [self stopPlayback];
            return;
        case AudioQueueState_Recording:
            [self stopRecording];
            break;
        default:
            break;
    }
    
    NSError *error;
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    NSAssert(error == nil, @"Error");
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    NSAssert(error == nil, @"Error");
    
    [self startPlayback];
}

- (void)startPlayback {
    currentByte = 0;
    OSStatus status = AudioFileOpenURL((__bridge CFURLRef) (self.audioFileURL),
                                kAudioFileReadPermission,
                                kAudioFileWAVEType,
                                &audioFileID);
    NSAssert(status == noErr, @"Error");
    
    status = AudioQueueNewOutput(&audioFormat,
                                 AudioOutputCallback,
                                 (__bridge void*)self,
                                 CFRunLoopGetCurrent(),
                                 kCFRunLoopCommonModes,
                                 0,
                                 &queue);
    NSAssert(status == noErr, @"Error");

    self.currentState = AudioQueueState_Playing;
    
    for (int i = 0; i < NUM_BUFFERS && self.currentState == AudioQueueState_Playing; i++) {
        status = AudioQueueAllocateBuffer(queue,
                                          16000,
                                          &buffers[i]);
        NSAssert(status == noErr, @"Error");
        
        AudioOutputCallback((__bridge void*)self,
                            queue,
                            buffers[i]);
        status = AudioQueueStart(queue, NULL);
        NSAssert(status == noErr, @"Error");
    }
}
@end
