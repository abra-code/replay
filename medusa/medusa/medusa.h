//
//  medusa.h
//  medusa
//
//  Created by Tomasz Kukielka on 7/5/19.
//  Copyright © 2019 Tomasz Kukielka. All rights reserved.
//

#ifndef medusa_h
#define medusa_h

#include <vector>
#include <string>
#include <unordered_set>
#include <unordered_map>

struct file_spec
{
    std::string path;
    size_t path_index;
};

//raw description of detached medusa
struct medusa
{
    std::string name;
    std::vector<file_spec> inputs;
    std::vector<file_spec> outputs;
    bool is_processed { false };
};

struct file_producer_and_consumers
{
    medusa* producer { nullptr }; //a pointer because the producer needs to be found dynamically
    std::unordered_set<medusa*> consumers;
    bool is_built { false };
};


int verify_all_medusas_have_been_processed(std::vector<medusa>& all_medusas);

void conect_medusas_v1(std::vector<medusa>& all_medusas);
void conect_medusas_v2(std::vector<medusa>& all_medusas);

#endif /* medusa_h */
