//
//  main.cpp
//  medusa
//
//  Created by Tomasz Kukielka on 7/5/19.
//  Copyright © 2019 Tomasz Kukielka. All rights reserved.
//

#include "medusa.h"
#include <iostream>
#include <random>
#include "hi_res_timer.h"


/*
    Well formed medusa specification:
    - unique/not duplicate outputs (medusa's out tentacles belong only to one medusa)
    - static inputs (anchored to islands) can be recognized in first pass - in medusa 1 & 2, removed in medusa 3
    - outputs are not allowed to be produced in static input location so it is quick to distinguish the two
    - some medusas have only static anchors and these are the starters
    - no circular connections (there must be a way to find the first medusa without dynamic artifact dependency)
 */



/* 3-node, well formed medusa set
M1,  static inputs only, no other node dependency
    i: S1, S2, S3
    <M1>
    o: B1_0, B1_1
 
 
 M2, depends on B1_0 from M1
 
    i: S1, S3, B1_0, S4
    <M2>
    o: B2_0

M3, depends on B1_0 from M1 and B2_0 from M2, produces unused B3_0
    i: B1_0, B2_0, S5
    <M3>
    o: B3_0

 */



std::vector<medusa> generate_three_test_medusas()
{
    std::cout << "Generating 3 test medusas\n";

    medusa medusa1;
    medusa1.name = "M1";
    medusa1.inputs.push_back({"S1"});
    medusa1.inputs.push_back({"S2"});
    medusa1.inputs.push_back({"S3"});
    medusa1.outputs.push_back({"B1_0"});
    medusa1.outputs.push_back({"B1_1"});

    medusa medusa2;
    medusa2.name = "M2";
    medusa2.inputs.push_back({"S1"});
    medusa2.inputs.push_back({"S3"});
    medusa2.inputs.push_back({"B1_0"});
    medusa2.inputs.push_back({"S4"});
    medusa2.outputs.push_back({"B2_0"});

    medusa medusa3;
    medusa3.name = "M3";
    medusa3.inputs.push_back({"B1_0"});
    medusa3.inputs.push_back({"B2_0"});
    medusa3.inputs.push_back({"S5"});
    medusa3.outputs.push_back({"B3_0"});
    
    std::vector<medusa> test_medusas;
    
    test_medusas.push_back(medusa1);
    test_medusas.push_back(medusa2);
    test_medusas.push_back(medusa3);
    
    return test_medusas;
}


static std::vector<medusa> generate_test_medusas(size_t medusa_count,
                                    size_t max_static_input_count, //>0
                                    size_t max_dynamic_input_count, //>=0
                                    size_t max_output_count) //>0
{
    std::cout << "Generating " << medusa_count << " test medusas\n";
    hi_res_timer timer;
    std::vector<medusa> test_medusas;
    test_medusas.resize(medusa_count);

    std::random_device randomizer;
    assert(max_static_input_count > 0);
    std::uniform_int_distribution<size_t> static_input_distibution(1, max_static_input_count-1);
    std::uniform_int_distribution<size_t> dynamic_input_distibution(0, max_dynamic_input_count-1);
    assert(max_output_count > 0);
    std::uniform_int_distribution<size_t> output_distibution(1, max_output_count-1);

    for(size_t i = 0; i < medusa_count; i++)
    {
        std::string counter_string = std::to_string(i);
        size_t static_input_count = static_input_distibution(randomizer);
        //don't bother adding dynamic inputs to lower count medusas until we get enough static-only ones with some outputs to use
        size_t dynamic_input_count = (i < max_dynamic_input_count) ? 0 : dynamic_input_distibution(randomizer);
        size_t output_count = output_distibution(randomizer);
        medusa &one_medusa = test_medusas[i];
        one_medusa.name = "M" + counter_string;
        one_medusa.inputs.resize(static_input_count+dynamic_input_count);
        for(size_t j = 0; j < static_input_count; j++)
        {
            one_medusa.inputs[j].path = "S" + std::to_string(i*1000 + j);
        }

        //dynamic inputs are chosen at random from medusas with lower indexes
        
        for(size_t j = 0; j < dynamic_input_count; j++)
        {
            //pick at random some output from a lower-index medusa
            size_t lower_medusa_index = 0;
            size_t lower_medusa_output_count = 0;
            std::uniform_int_distribution<size_t> lower_medusa_distibution(0, i-1);
            do
            {
                lower_medusa_index = lower_medusa_distibution(randomizer);
                medusa& lower_medusa = test_medusas[lower_medusa_index];
                lower_medusa_output_count = lower_medusa.outputs.size();
            } while(lower_medusa_output_count == 0);

            //TODO: this generator allows putting the same dynamic inputs more than once (does not matter with larger numeber of medusas)
            std::uniform_int_distribution<size_t> lower_medusa_output_distribution(0, lower_medusa_output_count-1);
            size_t lower_medusa_output_index = lower_medusa_output_distribution(randomizer);
            one_medusa.inputs[static_input_count+j].path = "D" + std::to_string(lower_medusa_index*1000 + lower_medusa_output_index);
        }

        one_medusa.outputs.resize(output_count);

        for(size_t j = 0; j < output_count; j++)
        {
            one_medusa.outputs[j].path = "D" + std::to_string(i*1000 + j);
        }

    }

    std::shuffle(test_medusas.begin(), test_medusas.end(), randomizer);
    double seconds = timer.elapsed();
    std::cout << "Finished medusa generation in " << seconds << " seconds\n";

    return test_medusas;
}

static void reset_medusas(std::vector<medusa>& all_medusas)
{
    for(size_t i = 0; i < all_medusas.size(); i++)
    {
        medusa& one_medusa = all_medusas[i];
        one_medusa.is_processed = false;
        size_t input_count = one_medusa.inputs.size();
        for(size_t ii = 0; ii < input_count; ii++)
        {
            one_medusa.inputs[ii].path_index = 0;
        }

        size_t output_count = one_medusa.outputs.size();
        for(size_t oi = 0; oi < output_count; oi++)
        {
            one_medusa.outputs[oi].path_index = 0;
        }
    }
}

static int verify_all_medusas_have_been_processed(std::vector<medusa>& all_medusas)
{
    bool all_processed = true;
    for(size_t i = 0; i < all_medusas.size(); i++)
    {
        medusa& one_medusa = all_medusas[i];
        all_processed = (all_processed && one_medusa.is_processed);
    }
    
    if(all_processed)
    {
        std::cout << "All medusa nodes have been processed successfully\n";
        return 0;
    }
    
    std::cout << "FAILURE: Not all medusa nodes have been processed!\n";
    return 255;
}


int main(int argc, const char * argv[])
{
    int err_code;
    std::vector<medusa> all_medusas = generate_test_medusas( 1000000, // medusa_count,
                                                            20, // max_static_input_count > 0
                                                            20, // max_dynamic_input_count, //>=0
                                                            20  // max_output_count > 0
                                                            );
    std::cout << "\nMedusa connector v1\n";
    conect_medusas_v1(all_medusas);
    err_code = verify_all_medusas_have_been_processed(all_medusas);

    std::cout << "\nMedusa connector v2\n";
    reset_medusas(all_medusas);
    conect_medusas_v2(all_medusas);
    err_code = verify_all_medusas_have_been_processed(all_medusas);

    std::cout << "\nMedusa connector v3\n";
    reset_medusas(all_medusas);
    conect_medusas_v3(all_medusas);
    err_code = verify_all_medusas_have_been_processed(all_medusas);
    return err_code;
}


