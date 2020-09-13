//
//  medusa3.cpp
//  medusa
//
//  Created by Tomasz Kukielka on 9/12/2020.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//
// medusa3 removes the assumption of separate input and out locations for quick classification
// this comes at the cost of checking each input if it is the output of some producer


#include "medusa.h"
#include <iostream>
#include <random>
#include "hi_res_timer.h"

static void index_all_outputs(std::vector<medusa>& all_medusas,
                       std::unordered_map< std::string, size_t >& output_paths_to_indexes_map,
                       std::vector<file_producer_and_consumers>& output_spec_list)
{
    std::cout << "First pass to index all output files\n";
    hi_res_timer timer;
    for(size_t mi = 0; mi < all_medusas.size(); mi++)
    {
        medusa& one_medusa = all_medusas[mi];

        size_t output_count = one_medusa.outputs.size();
        for(size_t oi = 0; oi < output_count; oi++)
        {
            file_producer_and_consumers producer_and_consumers;
            producer_and_consumers.producer = &one_medusa;
            output_spec_list.push_back(producer_and_consumers);
            size_t path_index = output_spec_list.size(); //intentionally +1 so index 0 is not a built product path
            one_medusa.outputs[oi].path_index = path_index;
            const std::string& one_output_path = one_medusa.outputs[oi].path;
            //no two producers can produce the same output - validation would be required
            output_paths_to_indexes_map[one_output_path] = path_index;
        }
    }

    double seconds = timer.elapsed();
    std::cout << "Total number of outputs in all medusas " << output_spec_list.size() << "\n";
    std::cout << "Finished indexing all outputs in " << seconds << " seconds\n";
}

static void connect_all_dynamic_inputs_v3(std::vector<medusa>& all_medusas, //input list of all raw unconnected medusas
                       std::vector<medusa*>& static_medusa_list, //medusas without dynamic dependencies to be executed first
                       const std::unordered_map< std::string, size_t >& output_paths_to_indexes_map, //the helper map produced in first pass
                       std::vector<file_producer_and_consumers>& output_spec_list) //the list of all output specs
{
    std::cout << "Connecting all dynamic inputs\n";
    
    hi_res_timer timer;
    size_t all_input_count = 0;
    size_t static_input_count = 0;

    //second pass - connect outputs to inputs, gather info about consumers and producers
    //find first medusas without dependencies
    for(size_t mi = 0; mi < all_medusas.size(); mi++)
    {
        medusa& one_medusa = all_medusas[mi];
        size_t input_count = one_medusa.inputs.size();
        bool are_all_inputs_satisfied = true;
        for(size_t ii = 0; ii < input_count; ii++)
        {
        	all_input_count++;
            const std::string &one_input_path = one_medusa.inputs[ii].path;
            
            //find if this medusa's input is known to be produced by another one
            auto output_path_iterator = output_paths_to_indexes_map.find(one_input_path);
            size_t found_output_index = 0;//index = 0 means the path is not an output from producer
            assert(one_medusa.inputs[ii].path_index == 0);
            if(output_path_iterator != output_paths_to_indexes_map.end())
            {
                found_output_index = output_path_iterator->second; //this is index+1
                assert(found_output_index > 0); //0 is a reserved index for static inputs
                one_medusa.inputs[ii].path_index = found_output_index; //for easy lookup later in output_spec_list
                file_producer_and_consumers& producer_and_consumers = output_spec_list[found_output_index-1];
                producer_and_consumers.consumers.insert(&one_medusa);// add oneself to the list of consumers
            }
            else
            {
            	static_input_count++;
            }

            are_all_inputs_satisfied = (are_all_inputs_satisfied && (found_output_index == 0));
        }
        
        if(are_all_inputs_satisfied)
        {
            one_medusa.is_processed = true;
            static_medusa_list.push_back( &one_medusa );
        }
    }
    
    double seconds = timer.elapsed();
    std::cout << "Finished connecting all dynamic outputs in " << seconds << " seconds\n";
    
    
    std::cout << "All input count " << all_input_count << "\n";
    std::cout << "Static input count " << static_input_count << "\n";
    std::cout << "Initial count of medusas with static dependencies only: " << static_medusa_list.size() << "\n";
}


static void execute_medusa_list(std::vector<medusa*>& medusa_list, std::vector<file_producer_and_consumers>& output_spec_list)
{
    std::vector<medusa*> next_medusa_list;
    size_t medusa_count = medusa_list.size();
    for(size_t mi = 0; mi < medusa_count; mi++)
    {
        medusa& one_node = *(medusa_list[mi]);
        
        /*
        std::cout << "\tExecuting medusa: " << one_node.name << "\n";

        size_t input_count = one_node.inputs.size();
        for(size_t j = 0; j < input_count; j++)
        {
            const std::string& one_input_path = one_node.inputs[j].path;
            size_t one_input_index = one_node.inputs[j].path_index;
            std::cout << "\t\tin: " << one_input_path << " index: " << one_input_index << "\n";
        }
        */
        
        size_t output_count = one_node.outputs.size();
        for(size_t oi = 0; oi < output_count; oi++)
        {
            size_t output_path_index = one_node.outputs[oi].path_index;
            assert(output_path_index > 0);
            file_producer_and_consumers& one_output_spec = output_spec_list[output_path_index-1];
            one_output_spec.is_built = true;

            //const std::string& one_output_path = one_node.outputs[oi].path;
            //std::cout << "\t\tout: " << one_output_path << " index: " << output_path_index << "\n";

             for(auto iter = one_output_spec.consumers.begin(); iter != one_output_spec.consumers.end(); ++iter )
             {
                 medusa& consumer_medusa = *(*iter);
                 bool are_all_inputs_satisfied = true;
                 size_t input_count = consumer_medusa.inputs.size();
                 for(size_t ii = 0; ii < input_count; ii++)
                 {
                     //const std::string &one_input_path = consumer_medusa.inputs[ii].path;
                     size_t input_path_index = consumer_medusa.inputs[ii].path_index;
                     bool is_input_satisfied = (input_path_index == 0); //index 0 is static
                     if(!is_input_satisfied)
                     {
                         file_producer_and_consumers& producer_and_consumers = output_spec_list[input_path_index-1];
                         is_input_satisfied = producer_and_consumers.is_built;
                     }
                     are_all_inputs_satisfied = (are_all_inputs_satisfied && is_input_satisfied);
                 }
                 
                 if(are_all_inputs_satisfied)
                 {
                     consumer_medusa.is_processed = true;
                     next_medusa_list.push_back( &consumer_medusa );
                 }

             }
        }
    }
    
    
    if(next_medusa_list.size() > 0)
    {
        //now recursively go over next medusas and follow the outputs to find the ones with all satisifed inputs
        execute_medusa_list(next_medusa_list, output_spec_list);
    }
    else
    {
        // std::cout << "No more medusas with all satsfied inputs found. Done\n";
    }
}

// medusa 3 builds on top of medusa 2 but works harder classifying inputs

// Perf results on MacBook Pro 2.7 GHz Quad-Core Intel Core i7 (release config, no debugging)
// Checking all inputs without easy static classification by prefix adds a cost
// In example 1 million medusas, there are about 20 million inputs, about 10 million of them are static
// the 10 million extra input lookups compared to medusa 2 add about 4 seconds to 10 seconds spent in connect_all_dynamic_inputs

void conect_medusas_v3(std::vector<medusa>& all_medusas)
{
    //this is a map of all outputs, each keeping a set of medusas which consume it
    std::unordered_map< std::string, size_t > output_paths_to_indexes_map;
    std::vector<file_producer_and_consumers> output_spec_list;
    std::vector<medusa*> static_medusa_list;
    
    index_all_outputs(all_medusas,
                      output_paths_to_indexes_map,
                      output_spec_list);

    connect_all_dynamic_inputs_v3(all_medusas, //input list of all raw unconnected medusas
                                    static_medusa_list, //medusas without dynamic dependencies to be executed first
                                    output_paths_to_indexes_map, //the helper map produced in first pass
                                    output_spec_list); //the list of all output specs

    std::cout << "Following medusa chain recursively\n";
    hi_res_timer timer;
    execute_medusa_list(static_medusa_list, output_spec_list);
    double seconds = timer.elapsed();
    std::cout << "Finished medusa execution in " << seconds << " seconds\n";
}
