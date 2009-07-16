#!/usr/bin/perl

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
use C4::Auth;
use C4::Context;
use C4::Koha;
use C4::Output;
use C4::Circulation;
use C4::Reports;
use C4::Members;
use C4::Dates qw/format_date_in_iso/;

=head1 NAME

plugin that shows expired or cancelled holds

=head1 DESCRIPTION

=over 2

=cut

my $input = new CGI;
my $do_it=$input->param('do_it');
my $fullreportname = "reports/expiredholds.tmpl";
my $output = $input->param("output");
my $basename = $input->param("basename");
my $mime = $input->param("MIME");

my $initstatement = "SELECT DISTINCT biblio.title as 'Title', borrowers.surname as 'Last Name', borrowers.firstname as 'First Name', old_reserves.cancellationdate as 'Date Cancelled/Expired', branches.branchname as 'Library' FROM old_reserves LEFT JOIN borrowers ON (old_reserves.borrowernumber = borrowers.borrowernumber) LEFT JOIN biblio ON (old_reserves.biblionumber = biblio.biblionumber) LEFT JOIN branches ON (old_reserves.branchcode = branches.branchcode)";

my $patron      = $input->param('patron')   || undef;
my $fromdate    = $input->param('from')    || undef;
my $todate      = $input->param('to')   || undef;
my $holdexpdate = $input->param('holdexpdate')   || undef;

my $endstatement = " ORDER BY borrowers.surname, old_reserves.reservedate";
my $fullstatement = $initstatement;
my $whereclause = 0;
if (defined($patron)) {
  my $patfilter = " WHERE borrowers.surname = '" . $patron . "'";
  $fullstatement .= $patfilter;
  $whereclause = 1;
}
my ($mm,$dd,$yyyy);
if (defined($fromdate)) {
  ($mm,$dd,$yyyy) = split(/\//,$fromdate);
  my $sqlfromdate = sprintf "%4d-%02d-%02d",$yyyy,$mm,$dd;
  my $fromfilter;
  if ($whereclause) {
    $fromfilter = " AND old_reserves.reservedate >= '" . $sqlfromdate . "'";
  }
  else {
    $fromfilter = " WHERE old_reserves.reservedate >= '" . $sqlfromdate . "'";
  }
  $fullstatement .= $fromfilter;
  $whereclause = 1;
}
if (defined($todate)) {
  ($mm,$dd,$yyyy) = split(/\//,$todate);
  my $sqltodate = sprintf "%4d-%02d-%02d",$yyyy,$mm,$dd;
  my $tofilter;
  if ($whereclause) {
    $tofilter = " AND old_reserves.reservedate <= '" . $sqltodate . "'";
  }
  else {
    $tofilter = " WHERE old_reserves.reservedate <= '" . $sqltodate . "'";
  }
  $fullstatement .= $tofilter;
}
if (defined($holdexpdate)) {
  ($mm,$dd,$yyyy) = split(/\//,$holdexpdate);
  my $sqltodate = sprintf "%4d-%02d-%02d",$yyyy,$mm,$dd;
  my $expfilter;
  if ($whereclause) {
    $expfilter = " AND old_reserves.cancellationdate = '" . $sqltodate . "'";
  }
  else {
    $expfilter = " WHERE old_reserves.cancellationdate = '" . $sqltodate . "'";
  }
  $fullstatement .= $expfilter;
}
if ($whereclause) {
  $fullstatement .= " AND (old_reserves.expirationdate IS NOT NULL OR old_reserves.waitingdate IS NOT NULL)";
}
else {
  $fullstatement .= " (old_reserves.expirationdate IS NOT NULL OR old_reserves.waitingdate IS NOT NULL)";
}
$fullstatement .= $endstatement;

our $sep     = $input->param("sep");
$sep = "\t" if ($sep eq 'tabulation');
my ($template, $borrowernumber, $cookie) = get_template_and_user(
        { template_name => $fullreportname,
          query => $input,
          type => "intranet",
          authnotrequired => 0,
          flagsrequired => {reports => 1},
          debug => 1,
        });
$template->param(do_it => $do_it,
        DHTMLcalendar_dateformat => C4::Dates->DHTMLcalendar(),
        );
if ($do_it)
{
  # Obtain results
  my @rows = ();
  my $dbh = C4::Context->dbh;
  my $sth = $dbh->prepare($fullstatement);
  $sth->execute();
  my $headref = $sth->{NAME} || [];
  my @headers = map { +{ cell => $_ } } @$headref;
  $template->param(header_row => \@headers);
  while (my $row = $sth->fetchrow_arrayref()) {
    my @cells = map { +{ cell => $_ } } @$row;
    push @rows, { cells => \@cells };
  }

  # Displaying results
  if ($output eq "screen") {
# Printing results to screen
    $template->param(header_row => \@headers);
    $template->param(results => \@rows);
    output_html_with_http_headers $input, $cookie, $template->output;
    exit(1);
  }
  else {
# Printing to a csv file
    print $input->header(-type => 'application/vnd.sun.xml.calc',
                         -encoding    => 'utf-8',
                         -attachment=>"$basename.csv",
                         -filename=>"$basename.csv" );
# Print column headers
    foreach my $head ( @headers ) {
      print $head->{cell}.$sep;
    }
    print "\r\n";
# Print table
    foreach my $row ( @rows ) {
      my $col = $row->{cells};
      foreach my $cell (@$col) {
        print $cell->{cell}.$sep;
      }
      print "\r\n";
    }
    exit(1);
  }
# Displaying choices
}
else {
  my $dbh = C4::Context->dbh;
  my @values;
  my %labels;
  my %select;
  my $req;

  my @mime = ( C4::Context->preference("MIME") );
  my $CGIextChoice=CGI::scrolling_list(
                -name     => 'MIME',
                -id       => 'MIME',
                -values   => \@mime,
                -size     => 1,
                -multiple => 0 );

  my $CGIsepChoice = GetDelimiterChoices;

  my ($codes,$labels) = GetborCatFromCatType(undef,undef);
  my @borcatloop;
  foreach my $thisborcat (sort keys %$labels) {
    my %row =(value => $thisborcat,
              description => $labels->{$thisborcat});
    push @borcatloop, \%row;
  }
  $template->param(
     CGIextChoice => $CGIextChoice,
     CGIsepChoice => $CGIsepChoice,
     borcatloop =>\@borcatloop,
  );
  output_html_with_http_headers $input, $cookie, $template->output;
}

1;
