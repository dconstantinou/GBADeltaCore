//
//  GBAEmulatorBridge.m
//  GBADeltaCore
//
//  Created by Riley Testut on 6/3/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

#import "GBAEmulatorBridge.h"
#import "GBASoundDriver.h"

// VBA-M
#include "System.h"
#include "gba/Sound.h"
#include "gba/GBA.h"
#include "gba/Cheats.h"
#include "gba/RTC.h"
#include "Util.h"

#include <sys/time.h>

// DeltaCore
#import <GBADeltaCore/GBADeltaCore.h>
#import <GBADeltaCore/GBADeltaCore-Swift.h>

// Required vars, used by the emulator core
//
int  systemRedShift = 19;
int  systemGreenShift = 11;
int  systemBlueShift = 3;
int  systemColorDepth = 32;
int  systemVerbose;
int  systemSaveUpdateCounter = 0;
int  systemFrameSkip;
uint32_t  systemColorMap32[0x10000];
uint16_t  systemColorMap16[0x10000];
uint16_t  systemGbPalette[24];

int  emulating;
int  RGB_LOW_BITS_MASK;

@interface GBAEmulatorBridge ()

@property (nonatomic, copy, nullable, readwrite) NSURL *gameURL;

@property (assign, nonatomic, getter=isFrameReady) BOOL frameReady;

@property (nonatomic) uint32_t activatedInputs;

@end

@implementation GBAEmulatorBridge
@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;

+ (instancetype)sharedBridge
{
    static GBAEmulatorBridge *_emulatorBridge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _emulatorBridge = [[self alloc] init];
    });
    
    return _emulatorBridge;
}

#pragma mark - Emulation -

- (void)startWithGameURL:(NSURL *)URL
{
    self.gameURL = URL;
    
    NSData *data = [NSData dataWithContentsOfURL:URL];
    
    if (!CPULoadRomData((const char *)data.bytes, (int)data.length))
    {
        return;
    }
    
    [self updateGameSettings];
        
    utilUpdateSystemColorMaps(NO);
    utilGBAFindSave((int)data.length);
    
    soundInit();
    soundSetSampleRate(32768); // 44100 chirps
    
    soundReset();
    
    CPUInit(0, false);
    
    GBASystem.emuReset();
    
    emulating = 1;
}

- (void)stop
{
    GBASystem.emuCleanUp();
    soundShutdown();
    
    emulating = 0;
}

- (void)pause
{
    emulating = 0;
}

- (void)resume
{
    emulating = 1;
}

- (void)runFrame
{
    self.frameReady = NO;
    
    while (![self isFrameReady])
    {
        GBASystem.emuMain(GBASystem.emuCount);
    }
}

#pragma mark - Settings -

- (void)updateGameSettings
{
    NSString *gameID = [NSString stringWithFormat:@"%c%c%c%c", rom[0xac], rom[0xad], rom[0xae], rom[0xaf]];
    
    NSLog(@"VBA-M: GameID in ROM is: %@", gameID);
    
    // Set defaults
    // Use underscores to prevent shadowing of global variables
    BOOL _enableRTC       = NO;
    BOOL _enableMirroring = NO;
    BOOL _useBIOS         = NO;
    int  _cpuSaveType     = 0;
    int  _flashSize       = 0x10000;
    
    // Read in vba-over.ini and break it into an array of strings
    NSString *iniPath = [[NSBundle bundleForClass:[self class]] pathForResource:@"vba-over" ofType:@"ini"];
    NSString *iniString = [NSString stringWithContentsOfFile:iniPath encoding:NSUTF8StringEncoding error:NULL];
    NSArray *settings = [iniString componentsSeparatedByString:@"\n"];
    
    BOOL matchFound = NO;
    NSMutableDictionary *overridesFound = [[NSMutableDictionary alloc] init];
    NSString *temp;
    
    // Check if vba-over.ini has per-game settings for our gameID
    for (NSString *s in settings)
    {
        temp = nil;
        
        if ([s hasPrefix:@"["])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"[" intoString:nil];
            [scanner scanUpToString:@"]" intoString:&temp];
            
            if ([temp caseInsensitiveCompare:gameID] == NSOrderedSame)
            {
                matchFound = YES;
            }
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"saveType="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"saveType=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _cpuSaveType = [temp intValue];
            [overridesFound setObject:temp forKey:@"CPU saveType"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"rtcEnabled="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"rtcEnabled=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _enableRTC = [temp boolValue];
            [overridesFound setObject:temp forKey:@"rtcEnabled"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"flashSize="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"flashSize=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _flashSize = [temp intValue];
            [overridesFound setObject:temp forKey:@"flashSize"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"mirroringEnabled="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"mirroringEnabled=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _enableMirroring = [temp boolValue];
            [overridesFound setObject:temp forKey:@"mirroringEnabled"];
            
            continue;
        }
        
        else if (matchFound && [s hasPrefix:@"useBios="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"useBios=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _useBIOS = [temp boolValue];
            [overridesFound setObject:temp forKey:@"useBios"];
            
            continue;
        }
        
        else if (matchFound)
            break;
    }
    
    if (matchFound)
    {
        NSLog(@"VBA: overrides found: %@", overridesFound);
    }
    
    // Apply settings
    rtcEnable(_enableRTC);
    mirroringEnable = _enableMirroring;
    doMirroring(mirroringEnable);
    cpuSaveType = _cpuSaveType;
    
    if (_flashSize == 0x10000 || _flashSize == 0x20000)
    {
        flashSetSize(_flashSize);
    }
    
}

#pragma mark - Inputs -

- (void)activateInput:(NSInteger)gameInput
{
    self.activatedInputs |= (uint32_t)gameInput;
}

- (void)deactivateInput:(NSInteger)gameInput
{
    self.activatedInputs &= ~((uint32_t)gameInput);
}

- (void)resetInputs
{
    self.activatedInputs = 0;
}

#pragma mark - Game Saves -

- (void)saveGameSaveToURL:(NSURL *)URL
{
    GBASystem.emuWriteBattery(URL.fileSystemRepresentation);
}

- (void)loadGameSaveFromURL:(NSURL *)URL
{
    GBASystem.emuReadBattery(URL.fileSystemRepresentation);
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    GBASystem.emuWriteState(URL.fileSystemRepresentation);
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    GBASystem.emuReadState(URL.fileSystemRepresentation);
}

#pragma mark - Cheats -

- (BOOL)addCheatCode:(NSString *)cheatCode type:(NSString *)type
{
    NSMutableCharacterSet *legalCharactersSet = [NSMutableCharacterSet hexadecimalCharacterSet];
    [legalCharactersSet addCharactersInString:@" "];
    
    if ([cheatCode rangeOfCharacterFromSet:[legalCharactersSet invertedSet]].location != NSNotFound)
    {
        return NO;
    }
    
    if ([type isEqualToString:CheatTypeActionReplay] || [type isEqualToString:CheatTypeGameShark])
    {
        NSString *sanitizedCode = [cheatCode stringByReplacingOccurrencesOfString:@" " withString:@""];
        
        if (sanitizedCode.length != 16)
        {
            return NO;
        }
        
        cheatsAddGSACode([sanitizedCode UTF8String], "code", true);
    }
    else if ([type isEqualToString:CheatTypeCodeBreaker])
    {
        if (cheatCode.length != 13)
        {
            return NO;
        }
        
        cheatsAddCBACode([cheatCode UTF8String], "code");
    }
    
    return YES;
}

- (void)resetCheats
{
    cheatsDeleteAll(true);
}

- (void)updateCheats
{
    
}

@end

#pragma mark - VBA-M -

void systemMessage(int _iId, const char * _csFormat, ...)
{
    NSLog(@"VBA-M: %s", _csFormat);
}

void systemDrawScreen()
{
    // Get rid of the first line and the last row
    dispatch_apply(160, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t y){
        memcpy([GBAEmulatorBridge sharedBridge].videoRenderer.videoBuffer + y * 240 * 4, pix + (y + 1) * (240 + 1) * 4, 240 * 4);
    });
    
    [[GBAEmulatorBridge sharedBridge] setFrameReady:YES];
}

bool systemReadJoypads()
{
    return true;
}

uint32_t systemReadJoypad(int joy)
{
    return [GBAEmulatorBridge sharedBridge].activatedInputs;
}

void systemShowSpeed(int _iSpeed)
{
    
}

void system10Frames(int _iRate)
{
    if (systemSaveUpdateCounter > 0)
    {
        systemSaveUpdateCounter--;
        
        if (systemSaveUpdateCounter <= SYSTEM_SAVE_NOT_UPDATED)
        {
            GBAEmulatorBridge.sharedBridge.saveUpdateHandler();
            
            systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;
        }
    }
}

void systemFrame()
{
    
}

void systemSetTitle(const char * _csTitle)
{

}

void systemScreenCapture(int _iNum)
{

}

uint32_t systemGetClock()
{
    timeval time;
    
    gettimeofday(&time, NULL);
    
    double milliseconds = (time.tv_sec * 1000.0) + (time.tv_usec / 1000.0);
    return milliseconds;
}

SoundDriver *systemSoundInit()
{
    soundShutdown();
    
    auto driver = new GBASoundDriver;
    return driver;
}

void systemUpdateMotionSensor()
{
}

uint8_t systemGetSensorDarkness()
{
    return 0;
}

int systemGetSensorX()
{
    return 0;
}

int systemGetSensorY()
{
    return 0;
}

int systemGetSensorZ()
{
    return 0;
}

void systemCartridgeRumble(bool)
{
}

void systemGbPrint(uint8_t * _puiData,
                   int  _iLen,
                   int  _iPages,
                   int  _iFeed,
                   int  _iPalette,
                   int  _iContrast)
{
}

void systemScreenMessage(const char * _csMsg)
{
}

bool systemCanChangeSoundQuality()
{
    return true;
}

bool systemPauseOnFrame()
{
    return false;
}

void systemGbBorderOn()
{
}

void systemOnSoundShutdown()
{
}

void systemOnWriteDataToSoundBuffer(const uint16_t * finalWave, int length)
{
}

void debuggerMain()
{
}

void debuggerSignal(int, int)
{
}

void log(const char *defaultMsg, ...)
{
    static FILE *out = NULL;
    
    if(out == NULL) {
        out = fopen("trace.log","w");
    }
    
    va_list valist;
    
    va_start(valist, defaultMsg);
    vfprintf(out, defaultMsg, valist);
    va_end(valist);
}
