//
//  OutputSerializer.m
//  replay
//
//  Created by Tomasz Kukielka on 11/25/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//
//  OutputSerializer is designed to ensure the output printed to stdout is sequential for concurrent actions
//  Actions are scheduled for execution as GCD blocks and are executed in undetermined order.
//  They may also print at the same time from different threads, potentially interleaving multiline output with other actions.
//  OutputSerializer creates a helper thread where all stdout print requests are handled. This ensures no two threads are printing at the same time.
//  Another functionality is to ensure the sequence of output as determined by task processing order - if requested - even if execution of tasks is parallel.
//  This might be useful for streaming/piping tasks to "replay" with predictable output.
//  There are a couple of reasons why this is an old-fashioned NSThread used with "performSelector:" instead of being a serial GCD queue:
//  - GCD resources are not infinite. GCD has a threadpool limit (64 threads in macOS as of this writing) so
//    we don't want to compete with actual tasks (potentially thousands) queued for execution in the same GCD pool
//  - this is a long-lived thread, which we would not want to park on some GCD thread and reduce the available threads
//  - we need to keep the current state and pending strings collection so an object asscociated with a thread fits very well

#import "OutputSerializer.h"

NS_ASSUME_NONNULL_BEGIN

@interface OutputSerializer()

@property(nonatomic, readonly, strong) NSThread *thread;
@property(nonatomic) CFMutableDictionaryRef pendingOutputs;
@property(nonatomic) NSInteger lastPrintedActionIndex;

@end //OutputSerializer

//helper object because we can only pass one param to [NSTread performSelector:onThread:withObject:waitUntilDone:]
@interface ActionOutputSpec : NSObject
	@property(nonatomic, strong) NSString *string; //the idea is to provide either a single string or an array but not both
	@property(nonatomic, strong) NSArray<NSString *> *array;
	@property(nonatomic) NSInteger actionIndex;
@end

@implementation ActionOutputSpec

@end //ActionOutputSpec

NS_ASSUME_NONNULL_END

static void EmptyCallback(__unused void *info)
{
}

@implementation OutputSerializer

+ (nonnull instancetype)sharedOutputSerializer
{
	static OutputSerializer *sOutputSerializer = nil;

    static dispatch_once_t sOnceToken;
    dispatch_once(&sOnceToken, ^{
        sOutputSerializer = [[OutputSerializer alloc] init];
    });

  return sOutputSerializer;
}

-(instancetype) init
{
	self = [super init];
	if(self != nil)
	{
		//the keys are ordered indexes cast to pointers, values CFStringRef/NSString *
		_pendingOutputs = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
		_lastPrintedActionIndex = -1; //-1 means nothing printed yet
		_thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain:) object:nil];
		_thread.name = @"stdout serializer";
		[_thread start];
		[self performSelector:@selector(ensureReady:) onThread:_thread withObject:nil waitUntilDone:YES];
	}
	return self;
}

//this object is a singleton, do not bother cleaning up in dealloc

// main entry point for the thread
// here we start a runloop which we never stop for the life of the process
// the runloop is needed to process and dispatch requests sent with [self performSelector:onThread:withObject:waitUntilDone:]

- (void)threadMain:(nullable id) __unused obj
{
	CFRunLoopSourceContext sourceContext = {0};
	sourceContext.perform = EmptyCallback;

	CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);

	// in replay we never stop the loop but in general case CFRunLoopStop stops it
	CFRunLoopRun();

	CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
	CFRelease(source);
}

static inline
void printStringOrArray(NSString *actionOutputString, NSArray<NSString *> *outputArray)
{
	if(actionOutputString != nil)
	{
		fprintf(stdout, "%s", [actionOutputString UTF8String]);
	}
	else if(outputArray != nil)
	{
		for(NSString *oneString in outputArray)
		{
			fprintf(stdout, "%s", [oneString UTF8String]);
		}
	}
}

static inline
void printPendingOutput(id pendingOutput)
{
	if((NSNull *)pendingOutput != [NSNull null])
	{
		if([pendingOutput isKindOfClass:[NSString class]])
		{
			fprintf(stdout, "%s", [(NSString*)pendingOutput UTF8String]);
		}
		else if([pendingOutput isKindOfClass:[NSArray class]])
		{
			NSArray<NSString *> *array = (NSArray<NSString *> *)pendingOutput;
			for(NSString *oneString in array)
			{
				fprintf(stdout, "%s", [oneString UTF8String]);
			}
		}
	}
}

// executing on the serial thread
- (void)printString:(nonnull ActionOutputSpec *)actionOutputSpec
{
	NSInteger actionIndex = actionOutputSpec.actionIndex;
	NSString *actionOutputString = actionOutputSpec.string;
	NSArray<NSString *> *outputArray = actionOutputSpec.array;

	if(actionIndex < 0)
	{ // client does not request ordering. Process in FIFO order
		assert((actionOutputString != nil) || (outputArray != nil));
		printStringOrArray(actionOutputString, outputArray);
	}
	else if((_lastPrintedActionIndex + 1) == actionIndex)
	{ // in order, print it
		printStringOrArray(actionOutputString, outputArray);
		_lastPrintedActionIndex = actionIndex;
		
		// check if there are any pending strings we can print if the order is now satisifed
		id pendingOutput = nil;
		do
		{
			NSInteger nextTaskIndex = _lastPrintedActionIndex + 1;
			pendingOutput = (__bridge id)CFDictionaryGetValue(_pendingOutputs, (const void *)nextTaskIndex);
			if(pendingOutput != nil)
			{
				printPendingOutput(pendingOutput);
				CFDictionaryRemoveValue(_pendingOutputs, (const void *)nextTaskIndex);
				_lastPrintedActionIndex = nextTaskIndex;
			}
		}
		while(pendingOutput != nil);
	}
	else if(actionIndex <= _lastPrintedActionIndex)
	{//this is a contract violation - the action indexes cannot be lower than the already processed ones
		printStringOrArray(actionOutputString, outputArray);
		// logic error, so abort in debug
		assert(actionIndex > _lastPrintedActionIndex);
	}
	else
	{ // out of order, store the string in pending dict but cannot print anything yet
		CFTypeRef objToAdd = nil;
		if(actionOutputString != nil)
			objToAdd = (__bridge CFStringRef)actionOutputString;
		else if(outputArray != nil)
			objToAdd = (__bridge CFArrayRef)outputArray;
		else // an action without output, we need to make sure we still process it so the indexes are sequential, so add as empty/null
			objToAdd = (__bridge CFTypeRef)[NSNull null];

		CFDictionarySetValue(_pendingOutputs, (const void *)actionIndex, objToAdd);
	}
}

// just an empty method to call synchronously after thread creation to ensure the runloop is started
- (void)ensureReady:(nullable id) __unused obj
{
}

// executing on the serial thread - meant to be executed with waiting after all tasks are completed
- (void)waitForAllOutput:(nullable id) __unused obj
{
	CFIndex pendingCount = CFDictionaryGetCount(_pendingOutputs);
	if(pendingCount != 0)
	{ // unexpected situation, try to deal as best as we can
		fprintf(stderr, "Not all task outputs have been printed before \"replay\" finished playlist execution\n");
		
		// OK, flush all that we have pending anyway
		CFIndex remainingPendingCount = pendingCount;
		do
		{
			NSInteger nextActionIndex = _lastPrintedActionIndex + 1;
			id pendingOutput = (__bridge id)CFDictionaryGetValue(_pendingOutputs, (const void *)nextActionIndex);
			if(pendingOutput != nil)
			{
				printPendingOutput(pendingOutput);
				CFDictionaryRemoveValue(_pendingOutputs, (const void *)nextActionIndex);
				_lastPrintedActionIndex = nextActionIndex;
				remainingPendingCount = CFDictionaryGetCount(_pendingOutputs);
			}
		}
		while(remainingPendingCount > 0);

		// logic error, so abort in debug
		assert(pendingCount == 0);
	}

	// reset for the potential next playlist
	_lastPrintedActionIndex = -1; //-1 means nothing printed yet
}

// executing on calling thread
- (void)scheduleOutputString:(nullable NSString *)string withActionIndex:(NSInteger)actionIndex
{
	ActionOutputSpec *actionOutputSpec = [ActionOutputSpec new];
	actionOutputSpec.string = string;
	actionOutputSpec.actionIndex = actionIndex;

	//this is not atomic but should be good enough to test if the thread entered the runloop already
	assert(self.thread.executing);

	[self performSelector:@selector(printString:) onThread:_thread withObject:actionOutputSpec waitUntilDone:NO];
}

// executing on calling thread
- (void)scheduleOutputStrings:(nullable NSArray<NSString*> *)array withActionIndex:(NSInteger)actionIndex
{
	ActionOutputSpec *actionOutputSpec = [ActionOutputSpec new];
	actionOutputSpec.array = array;
	actionOutputSpec.actionIndex = actionIndex;

	//this is not atomic but should be good enough to test if the thread entered the runloop already
	assert(self.thread.executing);

	[self performSelector:@selector(printString:) onThread:_thread withObject:actionOutputSpec waitUntilDone:NO];
}

@end // OutputSerializer


// if actionIndex < 0: ordering not requested, just schedule printing immediately in FIFO order
// if actionIndex >= 0: action index given, ordering requested

void
PrintSerializedString(OutputSerializer * _Nullable serializer,  NSString * _Nullable string, NSInteger actionIndex)
{
	if(serializer != nil)
	{
		[serializer scheduleOutputString:string withActionIndex:actionIndex];
	}
	else
	{
		fprintf(stdout, "%s", [string UTF8String]);
	}
}

void PrintSerializedStrings(OutputSerializer * _Nullable serializer, NSArray<NSString *> * _Nullable array, NSInteger actionIndex)
{
	if(serializer != nil)
	{
		[serializer scheduleOutputStrings:array withActionIndex:actionIndex];
	}
	else
	{
		for(NSString *oneString in array)
		{
			fprintf(stdout, "%s", [oneString UTF8String]);
		}
	}
}

// should be called after all tasks have been executed
// so we just need to wait for the tasks to finish
void
FlushSerializedOutputs(OutputSerializer * _Nonnull serializer)
{
	[serializer performSelector:@selector(waitForAllOutput:) onThread:serializer.thread withObject:nil waitUntilDone:YES];
}
