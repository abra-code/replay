//
//  hi_res_timer.h
//  medusa
//
//  Created by Tomasz Kukielka on 7/7/19.
//  Copyright © 2019 Tomasz Kukielka. All rights reserved.
//

#ifndef hi_res_timer_h
#define hi_res_timer_h

#include <chrono>

class hi_res_timer
{
public:
    hi_res_timer()
    : _start(std::chrono::high_resolution_clock::now())
    {}
    
    double elapsed() const
    {
        auto diff = std::chrono::high_resolution_clock::now() - _start;
        return std::chrono::duration_cast< std::chrono::duration<double, std::ratio<1> > >(diff).count();
    }
    
private:
    std::chrono::time_point<std::chrono::high_resolution_clock> _start;
};

#endif /* hi_res_timer_h */
