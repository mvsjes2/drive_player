#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/lib";
use lib "$FindBin::RealBin/../p5-google-restapi/lib";

use DrivePlayer::GUI;

DrivePlayer::GUI->new()->run();
