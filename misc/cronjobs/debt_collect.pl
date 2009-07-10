#!/usr/bin/perl -w
#-----------------------------------
# Copyright (c) Jesse Weaver, 2009
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
#-----------------------------------

=head1 NAME

debt_collect.pl - submit debt collection reports to a collections agency

=head1 DESCRIPTION

When run, this will find patrons that have to be sent to a collections agency.
It will add a fine to their accounts, then mark them as sent. For patrons that
have already been sent to the collections agency, a separate report will be
prepared detailing what fines have been paid or added.

=head1 SYNOPSIS

holds/daily_fee.pl [ --confirm ] [ -v | --verbose ] ...

 Options:
   -h | --help                 Print out help text
   --usage                     Print out a short usage message
   -c | --confirm              Send the reports, don't just show them
   -v | --verbose              Show the reports that would be sent
   -l | --library LIBRARY_CODE Only report patrons from this library
   -f | --fine COLLECTION_FINE Charge this much to patrons that are reported
   --letter LETTER_CODE        Letter code of the billing notice
   -w | --wait DAYS            How many days to wait to report patron
   --to EMAIL                  Send the reports to this email address
   --subject SUBJECT           Subject of the sent email
   --ignore PATRON_TYPE        Ignore borrowers of this type

=head1 OPTIONS

=over 8

=item B<-h|--help>

Print out help page for this script.

=item B<--usage>

Print out a short usage message, and exit.

=item B<-c|--confirm>

Do actually send the reports to the collections agency. If this is not
specified, --verbose is turned on, so you can see the reports that would be
sent, and the reports are not emailed.

=item B<-v|--verbose>

Show the reports that are being sent what fees are being charged to the
patrons. On by default unless --confirm is specified.

=item B<-l|--library>

Only send patrons from a specific library to the debt collections agency,
rather than those from all libraries. Should specify a library code.

=item B<-f|--fine>

Charge this amount to patrons that are sent to the debt collections agency. If
this is not specified, no fine will be charged. Should specify an amount.

=item B<--to>

Send the reports to this address. Can be specified multiple times, with an email
address each time.

=item B<-l|--letter>

The letter code of the billing notice (defaults to BILLING).

=item B<-w|--wait>

How many days to wait, including holidays and weekends, after the last billing
notice to send the patron to a debt collection agency.

=item B<--minimum>

Required total amount due before the script stops sending reports to the debt
collection agency.

=item B<--subject>

Subject and body of submitted email.

=back

=cut

use strict;
use warnings;
BEGIN {
    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/../kohalib.pl" };
}
use C4::Overdues::UniqueMgmt;
use C4::Branch qw( GetBranchName );
use C4::Circulation;
use C4::Overdues;
use C4::Accounts qw( manualinvoice );
use C4::Members;
use C4::Letters;
use Getopt::Long;
use Pod::Usage;

my ( $help, $usage, $branch, $verbose, $confirm, @to, @ignored );

my $subject = 'Debt Collect';
my $billing_notice = 'BILLING';
my $wait = 21;
my $send_fine = 10;
my $minimum = 25;

GetOptions(
    'h|help' => \$help,
    'usage' => \$usage,
    'l|library=s' => \$branch,
    'confirm' => \$confirm,
    'v|verbose' => \$verbose,
    'f|fine=f' => \$send_fine,
    'to=s' => \@to,
    'letter' => \$billing_notice,
    'w|wait=i' => \$wait,
    'ignore' => \@ignored,
    'min' => \$minimum,
    'subject' => \$subject,
) or pod2usage( 2 );
pod2usage( 1 ) if ( $usage );
pod2usage( -verbose => 2 ) if ( $help );

if ( $branch && !GetBranchName( $branch ) ) {
    print "Invalid branch $branch, cannot continue\n";
    exit 1;
}

unless ( @to ) {
    print "Must specify email addresses with --to";
    exit 1;
}

unless ( $confirm ) {
    $verbose = 1;     # If you're not running it for real, then the whole point is the print output.
    print "### TEST MODE -- NO ACTIONS TAKEN ###\n";
}

my $today = C4::Dates->new()->output( 'iso' );
my %calendars;
my @submitted;
my @updated;

# If $branch is not set, it is the same as not passing it
foreach my $borrower ( @{ GetNotifiedMembers( $billing_notice, $wait, $branch, @ignored ) } ) {
    print "$borrower->{firstname} $borrower->{surname} ($borrower->{cardnumber}): " if ( $verbose );
    my $sent_fine = GetFineByDescription( $borrower->{'borrowernumber'}, 'A', "Sent to collections agency" );
    my ( $total, $acctlines, $numlines ) = GetMemberAccountRecords( $borrower->{'borrowernumber'} );

    if ( $borrower->{'last_reported_date'} && $borrower->{'last_reported_amount'} > 0 ) {
        if ( $borrower->{'last_reported_date'} eq $today ) {
            print "skipping, already reported today\n" if ( $verbose );
            next;
        }

        if ( $borrower->{'last_reported_amount'} < $minimum ) {
            MarkMemberReported( $borrower->{'borrowernumber'}, 0 ) if ( $confirm );
            next;
        }

        if ( $borrower->{'last_reported_amount'} == $total ) {
            print "skipping, no difference\n" if ( $verbose );
            next;
        }

        print "updating\n" if ( $verbose );

        my $diff = $total - $borrower->{'last_reported_amount'}; # Amount we have to reconcile
        my ( $additional, $waived, $paid, $returned ) = ( 0, 0, 0, 0 );

        foreach my $acctline ( @$acctlines ) {
            next if ( $acctline->{'date'} lt $borrower->{'last_reported_date'} );
            next unless ( $acctline->{'amount'} );

            # The amounts, waived, paid, etc. are required to be negative

            if ( $acctline->{'amount'} < 0 ) {
                $diff -= $acctline->{'amount'};
                if ( $acctline->{'type'} && $acctline->{'type'} eq 'W' ) {
                    $waived += $acctline->{'amount'};
                } else {
                    # No reliable way to detect returned items at this time
                    $paid += $acctline->{'amount'};
                }
            } elsif ( $acctline->{'amountoutstanding'} ) {
                $diff -= $acctline->{'amountoutstanding'};
                $additional += $acctline->{'amountoutstanding'};
            }
        }
        
        if ( $diff < 0 ) {
            $paid += $diff;
        } elsif ( $diff > 0 ) {
            $additional += $diff;
        }

        push @updated, AddBorrowerUpdate( {
            %$borrower,
            total => $total,
            additional => $additional,
            returned => $returned,
            waived => $waived,
            paid => $paid,
        } );
    } else {
        next if ( $total < $minimum );

        if ( $confirm ) {
            manualinvoice( $borrower->{borrowernumber}, '', 'Sent to collections agency - ', 'A', $send_fine, '' );
            $total += $send_fine;
        }

        print "submitting\n" if ( $verbose );
        push @submitted, AddBorrowerSubmit( {
            %$borrower,
            total => $total,
            earliest_due => GetEarliestDueDate( $borrower->{'borrowernumber'} )
        } );   
    }

    MarkMemberReported( $borrower->{'borrowernumber'}, $total ) if ( $confirm );
}

my @attachments;

my $submitted_report = join( "\n", @submitted );

print "submitted: $submitted_report\n" if ( $verbose && $submitted_report );

push @attachments, { filename => 'submit.txt', type => 'text/plain', content => "# Koha submitted patrons for $today\n$submitted_report" } if ( $submitted_report );

my $updated_report = join( "\n", @updated );

print "updated: $updated_report\n" if ( $verbose && $updated_report );
push @attachments, { filename => 'update.txt', type => 'text/plain', content => "# Koha updated patrons for $today\n$updated_report" } if ( $updated_report );

exit unless ( $confirm && @attachments );

my $letter = {
    code => 'DEBT_COLLECT',
    title => $subject,
    content => $subject,
};

foreach my $email ( @to ) {
    print "sending reports to $email";

    C4::Letters::EnqueueLetter( {
        borrowernumber => 1,
        to_address => $email,
        letter => $letter,
        message_transport_type => 'email',
        attachments => \@attachments
    } );
}
