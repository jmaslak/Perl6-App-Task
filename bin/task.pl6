#!/usr/bin/env perl6
use v6;

#
# Copyright (C) 2018 Joelle Maslak
# All Rights Reserved - See License
#

use lib $*PROGRAM.parent.add("lib");

use App::Tasks;

sub MAIN(+@args, :$expire-today?) {
    my $task = App::Tasks.new();
    $task.start(@args, :expire-today($expire-today // False));
}
