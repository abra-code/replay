//
//  medusa1.cpp
//  medusa
//
//  Created by Tomasz Kukielka on 7/5/19.
//  Copyright © 2019 Tomasz Kukielka. All rights reserved.
//

#include "medusa.h"
#include <iostream>
#include <random>
#include "hi_res_timer.h"


//input type classification based on known locations for static inputs
static bool is_static_input(const std::string &in_path)
{
    return (in_path[0] == 'S');
}

static void visit_all_medusas(std::vector<medusa>& all_medusas, std::vector<medusa*>& static_medusa_list, std::unordered_map< std::string, file_producer_and_consumers >& outputs_map)
{
    std::cout << "First pass on raw unconnected medusa list\n";
    
    hi_res_timer timer;
    size_t all_input_count = 0;
	size_t static_input_count = 0;
   
    size_t all_output_count = 0;
    //first pass - classify inputs/outputs, gather info about consumers and producers
    //find first medusas without dependencies
    for(size_t mi = 0; mi < all_medusas.size(); mi++)
    {
        medusa& one_medusa = all_medusas[mi];
        size_t input_count = one_medusa.inputs.size();
        bool are_all_inputs_satisfied = true;
        for(size_t ii = 0; ii < input_count; ii++)
        {
        	all_input_count++;
            const std::string &one_input = one_medusa.inputs[ii].path;
            bool is_input_satisfied = is_static_input(one_input);
            if(!is_input_satisfied)
            {//non-static inputs are outputs from other medusas, this medusa is a consumer
                file_producer_and_consumers& producer_and_consumers = outputs_map[one_input];
                producer_and_consumers.consumers.insert(&one_medusa);
            }
			else
			{
				static_input_count++;
			}
            are_all_inputs_satisfied = (are_all_inputs_satisfied && is_input_satisfied);
        }
        
        if(are_all_inputs_satisfied)
        {
            one_medusa.is_processed = true;
            static_medusa_list.push_back( &one_medusa );
        }
        
        size_t output_count = one_medusa.outputs.size();
        for(size_t oi = 0; oi < output_count; oi++)
        {
            const std::string& one_output_path = one_medusa.outputs[oi].path;
            file_producer_and_consumers& producer_and_consumers = outputs_map[one_output_path];
            assert(producer_and_consumers.producer == nullptr);
            producer_and_consumers.producer = &one_medusa;
        }
        all_output_count += output_count;
    }
    
    double seconds = timer.elapsed();
    std::cout << "Total number of outputs in all medusas " << all_output_count << "\n";
    std::cout << "Finished visiting all medusas in " << seconds << " seconds\n";
    
    std::cout << "All input count " << all_input_count << "\n";
    std::cout << "Static input count " << static_input_count << "\n";
    std::cout << "Initial count of medusas with static dependencies only: " << static_medusa_list.size() << "\n";
}


static void execute_medusa_list(std::vector<medusa*>& medusa_list, std::unordered_map< std::string, file_producer_and_consumers >& outputs_map)
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
            const std::string& one_input = one_node.inputs[j].path;
            std::cout << "\t\tin: " << one_input << "\n";
        }
        */
        
        size_t output_count = one_node.outputs.size();
        for(size_t oi = 0; oi < output_count; oi++)
        {
            const std::string& one_output_path = one_node.outputs[oi].path;
            file_producer_and_consumers& one_output_spec = outputs_map[one_output_path];
            one_output_spec.is_built = true;
            //std::cout << "\t\tout: " << one_output << "\n";

             for(auto iter = one_output_spec.consumers.begin(); iter != one_output_spec.consumers.end(); ++iter )
             {
                 medusa& one_medusa = *(*iter);
                 bool are_all_inputs_satisfied = true;
                 size_t input_count = one_medusa.inputs.size();
                 for(size_t ii = 0; ii < input_count; ii++)
                 {
                     const std::string &one_input_path = one_medusa.inputs[ii].path;
                     bool is_input_satisfied = is_static_input(one_input_path);
                     if(!is_input_satisfied)
                     {
                         file_producer_and_consumers& producer_and_consumers = outputs_map[one_input_path];
                         is_input_satisfied = producer_and_consumers.is_built;
                     }
                     are_all_inputs_satisfied = (are_all_inputs_satisfied && is_input_satisfied);
                 }
                 
                 if(are_all_inputs_satisfied)
                 {
                     one_medusa.is_processed = true;
                     next_medusa_list.push_back( &one_medusa );
                 }

             }
        }
    }
    
    
    if(next_medusa_list.size() > 0)
    {
        //now recursively go over next medusas and follow the outputs to find the ones with all satisifed inputs
        execute_medusa_list(next_medusa_list, outputs_map);
    }
    else
    {
        // std::cout << "No more medusas with all satsfied inputs found. Done\n";
    }
}

void conect_medusas_v1(std::vector<medusa>& all_medusas)
{
    //this is a map of all outputs, each keeping a set of medusas which consume it
    std::unordered_map< std::string, file_producer_and_consumers > outputs_map;
    std::vector<medusa*> static_medusa_list;

    visit_all_medusas(all_medusas, static_medusa_list, outputs_map);
    
    
    std::cout << "Following medusa chain recursively\n";
    hi_res_timer timer;
    execute_medusa_list(static_medusa_list, outputs_map);
    double seconds = timer.elapsed();
    std::cout << "Finished medusa execution in " << seconds << " seconds\n";
}
