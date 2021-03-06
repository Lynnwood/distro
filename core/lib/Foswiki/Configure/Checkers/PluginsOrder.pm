# See bottom of file for license and copyright information
package Foswiki::Configure::Checkers::PluginsOrder;

use strict;
use warnings;

use Foswiki::Configure::Checker ();
use File::stat;
our @ISA = ('Foswiki::Configure::Checker');

sub check_current_value {
    my ($this, $reporter) = @_;

    my @plugins   = split( /[\s,]+/, $Foswiki::cfg{PluginsOrder} );
    my $count     = 0;
    my $foundTWCP = 0;

    foreach my $plug (@plugins) {
        unless ($plug =~ /^[A-Za-z0-9_]+Plugin$/) {
            $reporter->ERROR("Invalid plugin name $plug");
            next;
        }

        unless ($Foswiki::cfg{Plugins}{$plug}{Module}) {
            $reporter->WARN("$plug has no {Plugins}{$plug}{Module}");
        }

        my $enabled = $Foswiki::cfg{Plugins}{$plug}{Enabled};
        if ( $plug eq 'TWikiCompatibilityPlugin') {
            $foundTWCP = 1;
            if ($enabled ) {
                $reporter->WARN(
                    "$plug must be first in the list for proper operation" )
                    unless ( $count == 0 );
            }
        }
        $count++;
        unless ($enabled) {
            unless ( $plug eq 'TWikiCompatibilityPlugin' ) {
                $reporter->WARN( "$plug is not enabled or is not installed" );
            }
        }
    }

    if (  !$foundTWCP
        && $Foswiki::cfg{Plugins}{TWikiCompatibilityPlugin}{Enabled} )
    {
        $reporter->WARN(
'TWikiCompatibilityPlugin is enabled.  It  must be first in the list for proper operation'
        );
    }
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2014 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
