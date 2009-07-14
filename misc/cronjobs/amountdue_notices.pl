#!/usr/bin/perl -w
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
use warnings;

BEGIN {

    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/../kohalib.pl" };
}

use C4::Context;
use C4::Dates qw/format_date/;
use C4::Debug;
use C4::Members;
use C4::Letters;

use Getopt::Long;
use Pod::Usage;
use Text::CSV_XS;

=head1 NAME

amountdue_notices.pl - prepare messages to be sent to patrons for excessive amounts due

=head1 SYNOPSIS

amountdue_notices.pl [ -n ] [ -library <branchcode> ] [ -csv [ <filename> ] ] 

 Options:
   -help                          brief help message
   -man                           full documentation
   -n                             No email will be sent
   -library      <branchname>     only deal with excessive amountdues from this library
   -csv          <filename>       populate CSV file

=head1 OPTIONS

=over 8

=item B<-help>

Print a brief help message and exits.

=item B<-man>

Prints the manual page and exits.

=item B<-v>

Verbose. Without this flag set, only fatal errors are reported.

=item B<-n>

Do not send any email. Amountdue notices that would have been sent to
the patrons or to the admin are printed to standard out. CSV data (if
the -csv flag is set) is written to standard out or to any csv
filename given.

=item B<-library>

select excessive amountdues for one specific library. Use the value in the
branches.branchcode table.

=item B<-csv>

Produces CSV data. if -n (no mail) flag is set, then this CSV data is
sent to standard out or to a filename if provided. Otherwise, only
amountdues that could not be emailed are sent in CSV format to the admin.

=back

=head1 DESCRIPTION

This script is designed to alert patrons and administrators of account
amounts owed that equal or exceed the value set up in the 
C<OwedNotificationValue> system preference.

=head2 Configuration

The notification alert value is controlled by the value set up in the
C<OwedNotificationValue> system preference.  In addition, a sytem preference
called C<EnableOwedNotification> tells the Koha system whether to use this
notification ability at all.

The template used to craft the email is defined in the "Tools:
Notices" section of the staff interface to Koha under the Code of 'BILLING'.

=head2 Outgoing emails

Typically, messages are prepared for each patron with amounts due that
equal or exceed OwedNotificationValue.  Messages for whom there is no 
email address on file are collected and sent as attachments in a single 
email to each library administrator, or if that is not set, then to the 
email address in the C<KohaAdminEmailAddress> system preference.

These emails are staged in the outgoing message queue, as are messages
produced by other features of Koha. This message queue must be
processed regularly by the
F<misc/cronjobs/process_message_queue.pl> program.

In the event that the C<-n> flag is passed to this program, no emails
are sent. Instead, messages are sent on standard output from this
program. They may be redirected to a file if desired.

=head2 Templates

Templates can contain variables enclosed in double angle brackets like
E<lt>E<lt>thisE<gt>E<gt>. Those variables will be replaced with values
specific to the relevant patron. Available variables
are:

=over

=item E<lt>E<lt>bibE<gt>E<gt>

the name of the library

=item E<lt>E<lt>borrowers.*E<gt>E<gt>

any field from the borrowers table

=item E<lt>E<lt>branches.*E<gt>E<gt>

any field from the branches table

=back

=head2 CSV output

The C<-csv> command line option lets you specify a file to which
amountdues data should be output in CSV format.

With the C<-n> flag set, data about all excessive amountdues is written to the
file. Without that flag, only information about excessive amountdues that were
unable to be sent directly to the patrons will be written. In other words, this
CSV file replaces the data that is typically sent to the administrator email 
address.

=head1 USAGE EXAMPLES

C<amountdue_notices.pl> - In this most basic usage, with no command line
arguments, all libraries are procesed individually, and notices are
prepared for all patrons with excessive amounts due for whom we have email
addresses. Messages for those patrons for whom we have no email
address are sent in a single attachment to the library administrator's
email address, or to the address in the KohaAdminEmailAddress system
preference.

C<amountdue_notices.pl -n -csv /tmp/amountdues.csv> - sends no email and
populates F</tmp/amountdues.csv> with information about all excessive amounts
due.

C<amountdue_notices.pl -library MAIN> - prepare notices of
excessive amountdues for the MAIN library.

=cut

# These variables are set by command line options.
# They are initially set to default values.
my $help    = 0;
my $man     = 0;
my $verbose = 0;
my $nomail  = 0;
my $mybranch;
my $csvfilename;

GetOptions(
    'help|?'         => \$help,
    'man'            => \$man,
    'v'              => \$verbose,
    'n'              => \$nomail,
    'library=s'      => \$mybranch,
    'csv:s'          => \$csvfilename,    # this optional argument gets '' if not supplied.
) or pod2usage(2);
pod2usage(1) if $help;
pod2usage( -verbose => 2 ) if $man;

if ( defined $csvfilename && $csvfilename =~ /^-/ ) {
    warn qq(using "$csvfilename" as filename, that seems odd);
}

if (!C4::Context->preference('EnableOwedNotification')) {
  die 'EnableOwedNotification is not turned on';
}
my $letter_code = 'BILLING';

my $branch_hashref = C4::Branch::GetBranches();
my $branchcount = keys %$branch_hashref;
$verbose and warn "Branchcount = $branchcount\n";
my @branches;
if ($branchcount) {
    my $branch_word = keys %$branch_hashref > 1 ? 'branches' : 'branch';
    foreach my $branch (sort keys %$branch_hashref) {
      push @branches,$branch_hashref->{$branch}->{branchcode};
    }     
    $verbose and warn "Found $branchcount $branch_word: " . join ( ', ', map { "'$_'" } @branches ) . "\n";
} else {
    die 'No branches available';
}

if ($mybranch) {
    $verbose and warn "Branch $mybranch selected\n";
    if ( scalar grep { $mybranch eq $_ } @branches ) {
        @branches = ($mybranch);
    } else {
        $verbose and warn "No active branch '$mybranch'\n";
        ( scalar grep { '' eq $_ } @branches )
          or die "No active overduerules for DEFAULT either!";
        $verbose and warn "Falling back on default rules for $mybranch\n";
        @branches = ('');
    }
}

my $dbh = C4::Context->dbh();
binmode( STDOUT, ":utf8" );

our $csv;       # the Text::CSV_XS object
our $csv_fh;    # the filehandle to the CSV file.
if ( defined $csvfilename ) {
    $csv = Text::CSV_XS->new( { binary => 1 } );
    if ( $csvfilename eq '' ) {
        $csv_fh = *STDOUT;
    } else {
        open $csv_fh, ">", $csvfilename or die "unable to open $csvfilename: $!";
    }
    if ( $csv->combine(qw(name surname address1 address2 zipcode city email itemcount itemsinfo)) ) {
        print $csv_fh $csv->string, "\n";
    } else {
        $verbose and warn 'combine failed on argument: ' . $csv->error_input;
    }
}

foreach my $branchcode (@branches) {

    my $branch_details = C4::Branch::GetBranchDetail($branchcode);
    my $admin_email_address = $branch_details->{'branchemail'} || C4::Context->preference('KohaAdminEmailAddress');
    my @output_chunks;    # may be sent to mail or stdout or csv file.

    $verbose and warn sprintf "branchcode : '%s' using %s\n", $branchcode, $admin_email_address;

    my $notify_value = C4::Context->preference('OwedNotificationValue');
    my $sth = $dbh->prepare( <<'END_SQL' );
SELECT borrowernumber, SUM(amountoutstanding) AS amountdue
  FROM accountlines
  GROUP BY borrowernumber
  HAVING SUM(amountoutstanding) >= ?
END_SQL

    $sth->execute( $notify_value );
    while ( my $patron_hits = $sth->fetchrow_hashref() ) {
      my $patron = GetMemberDetails($patron_hits->{borrowernumber});
    
      my $letter = C4::Letters::getletter( 'circulation', $letter_code );
      unless ($letter) {
        $verbose and warn "Message '$letter_code' content not found";
        last;
      }

      my $amount_due = sprintf "%.2f",$patron_hits->{amountdue};
      $verbose and warn "Patron: $patron->{borrowernumber} Amount: $amount_due\n";

      my $sth2 = $dbh->prepare("SELECT date,description,amountoutstanding
                                FROM accountlines
                                WHERE borrowernumber = ?
                                  AND amountoutstanding > 0.0");
      $sth2->execute($patron->{borrowernumber});
      my $outstanding_items = "";
      while (my @rows = $sth2->fetchrow_array()) {
        $outstanding_items .= join("\t",@rows) . "\n";
      }
      $letter = parse_letter(
         {   letter         => $letter,
             borrowernumber => $patron->{borrowernumber},
             branchcode     => $branchcode,
             substitute     => {
               bib             => $branch_details->{'branchname'},
               totalamountdue  => $amount_due,
               'items.content' => $outstanding_items
             }
         }
      );
    
      my @misses = grep { /./ } map { /^([^>]*)[>]+/; ( $1 || '' ); } split /\</, $letter->{'content'};
      if (@misses) {
        $verbose and warn "The following terms were not matched and replaced: \n\t" . join "\n\t", @misses;
      }
      $letter->{'content'} =~ s/\<[^<>]*?\>//g;    # Now that we've warned about them, remove them.
      $letter->{'content'} =~ s/\<[^<>]*?\>//g;    # 2nd pass for the double nesting.
    
# Check the borrowers.amount_notify_date field.  If it IS NULL, then
# queue a notification for the patron and update the amount_notify_date field
# with the current date.  This avoids queueing and sending notifications
# after the initial notification.  Other code will set the amount_notify_date
# field back to NULL when the account drops below OwedNotificationValue.

      $sth2 = $dbh->prepare( <<'END_SQL' );
SELECT *
  FROM borrowers
 WHERE borrowernumber = ?
END_SQL
      $sth2->execute( $patron->{borrowernumber} );
      while (my $notify_check = $sth2->fetchrow_hashref()) {

        if (!$notify_check->{amount_notify_date}) {
          my $sth3 = $dbh->prepare( <<'END_SQL' );
UPDATE borrowers
   SET amount_notify_date = CURDATE()
 WHERE borrowernumber = ?
END_SQL
          $sth3->execute( $patron->{borrowernumber} );

          if ($nomail) {
    
            push @output_chunks,
              prepare_letter_for_printing(
                {   letter         => $letter,
                    borrowernumber => $patron->{borrowernumber},
                    firstname      => $patron->{firstname},
                    lastname       => $patron->{surname},
                    address1       => $patron->{address},
                    address2       => $patron->{address2},
                    city           => $patron->{city},
                    postcode       => $patron->{zipcode},
                    email          => $patron->{email},
                    outputformat   => defined $csvfilename ? 'csv' : '',
                }
              );
          } else {
            if ($patron->{email}) {
              C4::Letters::EnqueueLetter(
                {   letter                 => $letter,
                    borrowernumber         => $patron->{borrowernumber},
                    message_transport_type => 'email',
                    from_address           => $admin_email_address,
                    to_address             => $patron->{email}
                }
              );
            } else {
              # If we don't have an email address for this patron, send it to the admin to deal with.
              push @output_chunks,
                prepare_letter_for_printing(
                  {   letter         => $letter,
                      borrowernumber => $patron->{borrowernumber},
                      firstname      => $patron->{firstname},
                      lastname       => $patron->{surname},
                      address1       => $patron->{address},
                      address2       => $patron->{address2},
                      city           => $patron->{city},
                      postcode       => $patron->{zipcode},
                      email          => $patron->{email},
                      outputformat   => defined $csvfilename ? 'csv' : '',
                  }
                );
            }
          }
        } else {
          $verbose and warn "$patron->{firstname} $patron->{surname} has already been notified on $notify_check->{amount_notify_date}\n";
        }
      } # fetchrow while
    }

    if (@output_chunks) {
        if ($nomail) {
            if ( defined $csvfilename ) {
                print $csv_fh @output_chunks;
            } else {
                local $, = "\f";    # pagebreak
                print @output_chunks;
            }
        } else {
            my $attachment = {
                filename => defined $csvfilename ? 'attachment.csv' : 'attachment.txt',
                type => 'text/plain',
                content => join( "\n", @output_chunks )
            };

            my $letter = {
                title   => 'Amountdue Notices',
                content => 'These messages were not sent directly to the patrons.',
            };
            C4::Letters::EnqueueLetter(
                {   letter                 => $letter,
                    borrowernumber         => undef,
                    message_transport_type => 'email',
                    attachments            => [$attachment],
                    to_address             => $admin_email_address,
                }
            );
        }
    }

}
if ($csvfilename) {

    # note that we're not testing on $csv_fh to prevent closing
    # STDOUT.
    close $csv_fh;
}

=head1 INTERNAL METHODS

These methods are internal to the operation of overdue_notices.pl.

=head2 parse_letter

parses the letter template, replacing the placeholders with data
specific to this patron, biblio, or item

named parameters:
  letter - required hashref
  borrowernumber - required integer
  substitute - optional hashref of other key/value pairs that should
    be substituted in the letter content

returns the C<letter> hashref, with the content updated to reflect the
substituted keys and values.


=cut

sub parse_letter {
    my $params = shift;
    foreach my $required (qw( letter borrowernumber )) {
        return unless exists $params->{$required};
    }

    if ( $params->{'substitute'} ) {
        while ( my ( $key, $replacedby ) = each %{ $params->{'substitute'} } ) {
            my $replacefield = "<<$key>>";

            $params->{'letter'}->{title}   =~ s/$replacefield/$replacedby/g;
            $params->{'letter'}->{content} =~ s/$replacefield/$replacedby/g;
        }
    }

    C4::Letters::parseletter( $params->{'letter'}, 'borrowers', $params->{'borrowernumber'} );

    if ( $params->{'branchcode'} ) {
        C4::Letters::parseletter( $params->{'letter'}, 'branches', $params->{'branchcode'} );
    }

    if ( $params->{'biblionumber'} ) {
        C4::Letters::parseletter( $params->{'letter'}, 'biblio',      $params->{'biblionumber'} );
        C4::Letters::parseletter( $params->{'letter'}, 'biblioitems', $params->{'biblionumber'} );
    }

    return $params->{'letter'};
}

=head2 prepare_letter_for_printing

returns a string of text appropriate for printing in the event that an
overdue notice will not be sent to the patron's email
address. Depending on the desired output format, this may be a CSV
string, or a human-readable representation of the notice.

required parameters:
  letter
  borrowernumber

optional parameters:
  outputformat

=cut

sub prepare_letter_for_printing {
    my $params = shift;

    return unless ref $params eq 'HASH';

    foreach my $required_parameter (qw( letter borrowernumber )) {
        return unless defined $params->{$required_parameter};
    }

    my $return;
    if ( exists $params->{'outputformat'} && $params->{'outputformat'} eq 'csv' ) {
        if ($csv->combine(
                $params->{'firstname'}, $params->{'lastname'}, $params->{'address1'},  $params->{'address2'}, $params->{'postcode'},
                $params->{'city'},      $params->{'email'},    $params->{'itemcount'}, $params->{'titles'}
            )
          ) {
            return $csv->string, "\n";
        } else {
            $verbose and warn 'combine failed on argument: ' . $csv->error_input;
        }
    } else {
        $return .= "$params->{'letter'}->{'content'}\n";

        # $return .= Data::Dumper->Dump( [ $params->{'borrowernumber'}, $params->{'letter'} ], [qw( borrowernumber letter )] );
    }
    return $return;
}
