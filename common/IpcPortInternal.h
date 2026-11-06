//
//  IpcPortInternal.h
//
//  Between IpcPort.cpp, which picks the backend, and the Unix domain socket backend in
//  IpcPortSocket.cpp. Not for the tools.
//

#pragma once

#include "IpcPort.h"

namespace ipc
{
namespace detail
{

std::unique_ptr<Port> CreateSocketLocal(const std::string &name, Handler handler);
std::unique_ptr<Port> CreateSocketRemote(const std::string &name);

} // namespace detail
} // namespace ipc
