#!/usr/bin/perl

#script to delete items
#written 2/5/00
#by chris@katipo.co.nz

# Copyright 2000-2002 Katipo Communications
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA

use strict;

use CGI;
use C4::Context;
use C4::Output;
use C4::Auth;
use C4::Members;

my $input = new CGI;

my ($template, $borrowernumber, $cookie)
                = get_template_and_user({template_name => "members/deletemem.tmpl",
                                        query => $input,
                                        type => "intranet",
                                        authnotrequired => 0,
                                        flagsrequired => {borrowers => 1},
                                        debug => 1,
                                        });

my $borrowernumber = $input->param('borrowernumber');
my $previous_cardnumber = $input->param('previous_cardnumber');

ModMember( borrowernumber => $borrowernumber, cardnumber => $previous_cardnumber );

print $input->redirect("/cgi-bin/koha/members/moremember.pl?borrowernumber=$borrowernumber");


