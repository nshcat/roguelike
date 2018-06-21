#pragma once

#include <string>
#include <vector>
#include <cl.hxx>
#include "global_system.hxx"

enum class cl_argument
{
	logger_verbosity,
	logger_verbose,
	logger_enable_file,
	logger_append_file
};

extern cl::handler g_clHandler;

extern ::std::vector<::std::string> g_argv;

auto populate_argv(int argc, const char** argv)
	-> void;
	
class commandline
	: public global_system
{
	public:
		auto initialize()
			-> void;
};
