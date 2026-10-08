/* Voice chat with Bluetooth headphones. While anything records from a Bluetooth headset's
 * microphone, macOS switches the headset to its hands-free profile: low-quality mono sound
 * both ways, for every app, and a second or two of silence at each switch (push-to-talk
 * loses words). When the Mac's default microphone is a Bluetooth headset and the Mac has a
 * built-in microphone that can hear (lid open), Wine's default input, for voice and
 * otherwise, becomes the built-in one, so the headset keeps playing high-quality sound.
 * Overwatch's "Default" microphone follows Wine's; a microphone chosen in the game wins.
 * Otherwise the values are removed and Wine follows macOS's default microphone again.
 * Wine names a device by its Core Audio UID: HKCU\Software\Wine\Drivers\winecoreaudio.drv\
 * devices\1,<UID> holds the GUID that makes its endpoint ID (mmdevapi's MMDevice_GetId). */
static UInt32 audioValue(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address={selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 value=0,size=sizeof(value);
    return AudioObjectGetPropertyData(object,&address,0,NULL,&size,&value)==noErr ? value : 0;
}
static BOOL lidClosed(void) {
    io_service_t domain=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"));
    if(!domain)return NO;
    CFTypeRef value=IORegistryEntryCreateCFProperty(domain,CFSTR("AppleClamshellState"),kCFAllocatorDefault,0);
    IOObjectRelease(domain);
    BOOL closed=value && CFGetTypeID(value)==CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if(value)CFRelease(value);
    return closed;
}
// The built-in microphone's UID when voice chat should use it; otherwise nil, and why.
static NSString *voiceMicrophoneUID(NSString **reason) {
    UInt32 input=audioValue(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultInputDevice);
    UInt32 transport=input ? audioValue(input,kAudioDevicePropertyTransportType) : 0;
    if(transport!=kAudioDeviceTransportTypeBluetooth && transport!=kAudioDeviceTransportTypeBluetoothLE) {*reason=@"default_microphone";return nil;}
    if(lidClosed()) {*reason=@"lid_closed";return nil;}
    AudioObjectPropertyAddress address={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&address,0,NULL,&size)!=noErr) {*reason=@"no_built_in_microphone";return nil;}
    NSMutableData *devices=[NSMutableData dataWithLength:size];
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,NULL,&size,devices.mutableBytes)!=noErr) {*reason=@"no_built_in_microphone";return nil;}
    const AudioObjectID *ids=devices.bytes;
    for(NSUInteger i=0;i<size/sizeof(AudioObjectID);i++) {
        if(audioValue(ids[i],kAudioDevicePropertyTransportType)!=kAudioDeviceTransportTypeBuiltIn || !audioValue(ids[i],kAudioDevicePropertyDeviceIsAlive))continue;
        AudioObjectPropertyAddress streams={kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};
        UInt32 streamSize=0;
        if(AudioObjectGetPropertyDataSize(ids[i],&streams,0,NULL,&streamSize)!=noErr || !streamSize)continue;
        AudioObjectPropertyAddress uidAddress={kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        CFStringRef uid=NULL;UInt32 uidSize=sizeof(uid);
        if(AudioObjectGetPropertyData(ids[i],&uidAddress,0,NULL,&uidSize,&uid)!=noErr || !uid)continue;
        *reason=@"bluetooth_microphone";return CFBridgingRelease(uid);
    }
    *reason=@"no_built_in_microphone";return nil;
}
// Recall's two values and the device's GUID, as user.reg holds them.
static NSDictionary *voiceRegistry(NSString *uid) {
    NSString *path=join(root,@"environment/user.reg");struct stat st;
    if(lstat(path.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) || st.st_size>(8<<20))return nil;
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if(!text)return nil;
    NSString *driver=@"[Software\\\\Wine\\\\Drivers\\\\winecoreaudio.drv]";
    NSString *device=uid ? [NSString stringWithFormat:@"[Software\\\\Wine\\\\Drivers\\\\winecoreaudio.drv\\\\devices\\\\1,%@]",uid] : nil;
    NSMutableDictionary *found=[NSMutableDictionary dictionary];int section=0;
    for(NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([line hasPrefix:@"["]) {section=[line hasPrefix:driver] ? 1 : (device && [line hasPrefix:device]) ? 2 : 0;continue;}
        if(section==1) for(NSString *name in @[@"DefaultVoiceInput",@"DefaultInput"]) {
            NSString *prefix=[NSString stringWithFormat:@"\"%@\"=\"",name];
            if([line hasPrefix:prefix] && [line hasSuffix:@"\""] && line.length>prefix.length)
                found[name]=[line substringWithRange:NSMakeRange(prefix.length,line.length-prefix.length-1)];
        }
        if(section==2 && [line hasPrefix:@"\"guid\"=hex:"]) {
            NSArray *bytes=[[line substringFromIndex:11] componentsSeparatedByString:@","];
            if(bytes.count!=16)continue;
            NSMutableData *guid=[NSMutableData dataWithCapacity:16];
            for(NSString *b in bytes) {
                if(!matches(b,@"^[0-9a-fA-F]{2}$"))break;
                uint8_t value=(uint8_t)strtoul(b.UTF8String,NULL,16);[guid appendBytes:&value length:1];
            }
            if(guid.length==16)found[@"guid"]=guid;
        }
    }
    return found;
}
// Wine's endpoint ID for a capture device with this GUID (a GUID's first three fields are little-endian).
static NSString *captureEndpointID(NSData *guid) {
    const uint8_t *b=guid.bytes;
    return [NSString stringWithFormat:@"{0.0.1.00000000}.{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
        (unsigned)(b[0]|b[1]<<8|b[2]<<16|(uint32_t)b[3]<<24),(unsigned)(b[4]|b[5]<<8),(unsigned)(b[6]|b[7]<<8),
        (unsigned)b[8],(unsigned)b[9],(unsigned)b[10],(unsigned)b[11],(unsigned)b[12],(unsigned)b[13],(unsigned)b[14],(unsigned)b[15]];
}
/* Sets Wine's default microphone as above. FORCED names a microphone to use instead of
 * asking Core Audio ("none": macOS's default), for support and tests; without APPLY it only
 * reports. Wine's reg.exe runs only when a value changes; with SETTLE, Wine's session then
 * ends, as after the Retina migration, so Battle.net starts a fresh one. Never fatal. */
static void configureVoiceMicrophone(NSString *engine, NSString *forced, BOOL apply, BOOL settle) {
    NSString *reason=@"requested";
    NSString *uid=forced ? ([forced isEqual:@"none"] ? nil : forced) : voiceMicrophoneUID(&reason);
    if(uid && !matches(uid,@"^[A-Za-z0-9._:,-]{1,128}$")) {uid=nil;reason=@"unsupported_device";}
    NSDictionary *registry=voiceRegistry(uid);
    if(!registry) {event(@"voice_microphone",@{@"device":@"unchanged",@"reason":@"registry_unreadable"});return;}
    NSData *guid=registry[@"guid"];BOOL newGuid=uid && !guid;
    if(newGuid) {uint8_t bytes[16];arc4random_buf(bytes,sizeof(bytes));guid=[NSData dataWithBytes:bytes length:sizeof(bytes)];}
    NSString *wanted=uid ? captureEndpointID(guid) : nil;
    NSMutableArray *changes=[NSMutableArray array];
    if(newGuid)[changes addObject:@"guid"];
    for(NSString *name in @[@"DefaultVoiceInput",@"DefaultInput"])
        if(wanted ? ![registry[name] isEqual:wanted] : registry[name]!=nil)[changes addObject:name];
    NSMutableDictionary *details=[@{@"device":uid ? @"built_in" : @"default",@"reason":reason,@"changes":changes} mutableCopy];
    if(wanted)details[@"id"]=wanted;
    if(apply && changes.count) {
        NSString *key=@"HKCU\\Software\\Wine\\Drivers\\winecoreaudio.drv";
        NSMutableString *hex=[NSMutableString string];
        for(NSUInteger i=0;i<guid.length;i++)[hex appendFormat:@"%02x",(unsigned)((const uint8_t *)guid.bytes)[i]];
        for(NSString *change in changes) {
            NSArray *arguments=[change isEqual:@"guid"] ?
                @[@"reg.exe",@"add",[NSString stringWithFormat:@"%@\\devices\\1,%@",key,uid],@"/v",@"guid",@"/t",@"REG_BINARY",@"/d",hex,@"/f"] :
                wanted ? @[@"reg.exe",@"add",key,@"/v",change,@"/t",@"REG_SZ",@"/d",wanted,@"/f"] : @[@"reg.exe",@"delete",key,@"/v",change,@"/f"];
            if(waitTask(task(join(engine,@"bin/wine"),arguments,wineEnv(engine),@"voice-microphone.log"),60)) {details[@"failed"]=change;break;}
        }
        // Wine's server outlives reg.exe by a few seconds. The update Agent may keep the
        // session alive longer; Battle.net then joins it, as it would anyway.
        if(settle)waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"voice-microphone-wait.log"),6);
    }
    event(@"voice_microphone",details);
}
