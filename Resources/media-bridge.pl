# Runs TopNotch's MediaRemote helper inside Apple's perl, which macOS allows
# to read the system now-playing state. Argument: path to the helper dylib.
use strict;
use DynaLoader;
my $handle = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($handle, "topnotch_media_stream") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::topnotch_media_stream", $symbol);
topnotch_media_stream();
