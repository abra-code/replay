//
//  Medusa.h
//
//  Created by Tomasz Kukielka on 9/13/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface PathSpec : NSObject
	@property(nonatomic, strong) NSString *path;
	@property(nonatomic) NSUInteger producerIndex;
	
	- (id)initWithPath:(NSString *)path;
@end


@interface Medusa : NSObject
	@property(nonatomic, strong) NSMutableArray<PathSpec*> *inputs;
	@property(nonatomic, strong) NSMutableArray<PathSpec*> *outputs;
@end

@interface OutputProducer : NSObject
	@property(nonatomic, strong) Medusa *producer;
	@property(nonatomic, strong) NSMutableSet<Medusa*> *consumers;
	@property(nonatomic) bool built;
@end

#ifdef __cplusplus
extern "C" {
#endif

void index_all_outputs(NSArray<Medusa *> *all_medusas,
						CFMutableDictionaryRef output_paths_to_indexes_map,
                       	NSMutableArray<OutputProducer*> *output_spec_list);

NSMutableArray<Medusa *> * //medusas without dynamic dependencies to be executed first produced here
connect_all_dynamic_inputs(NSArray<Medusa *> *all_medusas, //input list of all raw unconnected medusas
                       CFDictionaryRef output_paths_to_producer_indexes, //the helper map produced in first pass
                       NSArray<OutputProducer*> *output_producers); //the list of all output specs

void execute_medusa_list(NSMutableArray<Medusa *> *medusa_list, NSArray<OutputProducer*> *output_producers);

#ifdef __cplusplus
}
#endif
