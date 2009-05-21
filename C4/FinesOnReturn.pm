package C4::FinesOnReturn;

# Copyright 2008 Kyle Hall <kyle.m.hall@gmail.com> kylehall.info
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

require Exporter;

use vars qw($VERSION @ISA @EXPORT);

use C4::Context;

use DBI;
use POSIX;
use Date::Calc qw(Add_Delta_Days);
use List::Util qw(min);
use Data::Dumper;


# Set the version for version checking
$VERSION = 0.01;

=head1 NAME

C4::FinesOnReturn - Koha module for calculating fines on return/renewal.

=head1 SYNOPSIS

  use C4::Accounts::FinesOnReturn;

=head1 DESCRIPTION

This module is an alternative system to the current nightly fines generator.
With this system, a fine for an overdue item is calculated at the time of
return/renewal. The fine for the entire overdue period is treated as a single
fine.

=head1 FUNCTIONS

=over 2

=cut

@ISA = qw(Exporter);
@EXPORT = qw(&CreateFineOnReturn &CalculateFine);

## Function Calculate Fine
## Calculates the fine for the given barcode or itemnumber.
## $future_date is an optional date ( YYYY-MM-DD ) for estimating a fine in the future.
## Returns amount of fine.
sub CalculateFine {
  my $maxFine = C4::Context->preference('MaxFine');
  my ( $itembarcode, $itemnumber, $future_date ) = @_;

  warn "C4::FinesOnReturn::CalculateFine( \$itembarcode = $itembarcode, \$itemnumber = $itemnumber, \$future_date = $future_date )";
  warn "C4::FinesOnReturn::CalculateFine: \$maxFine = $maxFine";

  my $return_date = sprintf("%04d-%02d-%02d", (localtime(time))[5] + 1900, (localtime(time))[4] + 1, (localtime(time))[3]);
  if ( $future_date ) {
    $return_date = $future_date;
  }
  warn "C4::FinesOnReturn::CalculateFine: \$return_date = $return_date";

  my $dbh = C4::Context->dbh;

  my $fineData = _GetFineData( $itembarcode, $itemnumber, $future_date );


  if ( ( $fineData->{'replacementprice'} > 0 ) && ( $fineData->{'replacementprice'} < $maxFine ) ) {
    $maxFine = $fineData->{'replacementprice'};
    warn "C4::FinesOnReturn::CalculateFine: \$maxFine = $maxFine, updated to replacementprice";
  }

  warn "C4::FinesOnReturn::CalculateFine: Days Overdue: " . $fineData->{'days_overdue'};
  if ( $fineData->{'days_overdue'} < 1 ) { return 0; } ## Short circuit for speed

  my $issuing_rule = _GetIssuingRule( $fineData->{'categorycode'}, $fineData->{'itemtype'}, $fineData->{'holdingbranch'} );
  my $days_to_charge = $fineData->{'days_overdue'} - $issuing_rule->{'firstremind'} - _GetHolidaysBetween( $fineData->{'date_due'}, $return_date, $fineData->{'holdingbranch'} );
  if ( $days_to_charge < 1 ) { return 0; } ## Short circuit for speed

  if ( ! $issuing_rule->{'chargeperiod'} ) { $issuing_rule->{'chargeperiod'} = 1; }

  my $fine = $days_to_charge * $issuing_rule->{'fine'} / $issuing_rule->{'chargeperiod'};
  if ( $fine > $maxFine ) { $fine = $maxFine; }

  return $fine;
}

## Function CreateFineOnReturn
## This function accepts to arguments, $itembarcode and $itemnumber
## Only one is required, if both are passed $itemnumber will be used.
## NOTE: This function should be run right before an item is returned or renewed.
sub CreateFineOnReturn {
  my ( $itembarcode, $itemnumber ) = @_;
warn "C4::FinesOnReturn::CreateFinesOnReturn( \$itembarcode = $itembarcode, \$itemnumber = $itemnumber )";
  my $dbh = C4::Context->dbh;

  my $amount = CalculateFine( $itembarcode, $itemnumber );
warn "C4::FinesOnReturn::CreateFinesOnReturn: \$amount = $amount = CalculateFine( \$itembarcode = $itembarcode, \$itemnumber = $itemnumber )";

  my $fineData;
  if ( $amount > 0 ) {
     $fineData = _GetFineData( $itembarcode, $itemnumber );
     my $description = " $fineData->{'itemcallnumber'} : ( $fineData->{'barcode'} ) Issued: $fineData->{'issuedate'}, Due: $fineData->{'date_due'}, Returned: $fineData->{'date_returned'}";
     _CreateFine( $fineData->{'itemnumber'}, $fineData->{'borrowernumber'}, $amount, my $type = 'F', $description );
  }
  
  return $fineData->{'borrowernumber'};
}

## Function _CreateFine
## Creates the accountline in the db
sub _CreateFine {
  my ( $itemnum, $bornum, $amount, $type, $description ) = @_;
  my $dbh = C4::Context->dbh;

  my $itemData = _GetFineData( '', $itemnum );
  my $title = $itemData->{'title'};
  my $holdingBranch = $itemData->{'holdingbranch'};

  ## Get the next accountno from accountlines
  ## FIXME: Should accountlines.accountno just be set to autoincrement in MySQL?
  my $sth2 = $dbh->prepare("SELECT MAX( accountno ) FROM accountlines");
  $sth2->execute;
  my $accountno = $sth2->fetchrow_array + 1;
  $sth2->finish;

  if ( $amount > 0 ) {
    ## Insert the fine into the database
    my $sth3 = $dbh->prepare("INSERT INTO accountlines (
      borrowernumber, itemnumber, date, amount, description, accounttype, amountoutstanding, accountno )
      VALUES ( ?, ?, NOW(), ?, ?, 'F', ?, ? )");
    warn "_CreateFine:: Insert Data sth3->execute( $bornum, $itemnum, $amount, '$type: $title {$holdingBranch} $description', $amount, $accountno )";
    $sth3->execute( $bornum, $itemnum, $amount, "$type: $title {$holdingBranch} $description", $amount, $accountno );
    $sth3->finish;
  }

}


## Function getFineData
## This function returns an array associated array of data about the borrower and the item
## $future_date is an optional date ( YYYY-MM-DD ) for estimating a fine in the future.
sub _GetFineData {
  my ( $itembarcode, $itemnumber, $future_date ) = @_;
warn "C4::FinesOnReturn::_GetFineData( \$itembarcode = $itembarcode, \$itemnumber = $itemnumber, \$future_data = $future_date )";
  my $diff_date = "NOW()";
  if ( $future_date ) {
    $diff_date = "DATE( $future_date )";
  }

  my $dbh = C4::Context->dbh;

  my $sql = "SELECT items.itemnumber,
                    items.itemcallnumber,
                    items.replacementprice,
                    issues.date_due,
                    issues.issuedate,
                    DATEDIFF( $diff_date, issues.date_due ) as days_overdue,
                    borrowers.borrowernumber,
                    borrowers.categorycode,
                    biblioitems.itemtype,
                    items.price,
                    items.barcode,
                    items.holdingbranch,
                    biblio.title,
                    CURDATE() AS date_returned
          FROM items, issues, borrowers, biblio, biblioitems, branches, itemtypes
          WHERE
          issues.itemnumber = items.itemnumber
          AND borrowers.borrowernumber = issues.borrowernumber
          AND items.biblionumber = biblioitems.biblionumber
          AND items.biblionumber = biblio.biblionumber
          AND branches.branchcode = items.holdingbranch
          AND biblioitems.itemtype = itemtypes.itemtype
          AND issues.returndate IS NULL
           ";
  if ( $itembarcode ) {
    $sql .= "AND items.barcode = ?";
  } else {
    $sql .= "AND items.itemnumber = ?";
  }

warn "C4::FinesOnReturn::_GetFineData: SQL: $sql";

  my $sth = $dbh->prepare( $sql );

  if ( $itembarcode ) {
    $sth->execute( $itembarcode );
  } else {
    $sth->execute( $itemnumber );
  }

  my $fineData = $sth->fetchrow_hashref();

for my $key ( keys %$fineData ) {
  warn "C4::FinesOnReturn::_GetFineData: $key => " . $fineData->{"$key"};
}

  return $fineData;
}

## _GetIssuingRule takes the borrower categorycode, itemtype, and the item's holdingbranch
## And returns the proper issuing rule, if there is no exact issuing rule for the combination,
## it tries to match just the category code, if that fails it tries just the itemtype
## if that fails, it returns the default rule for the branch
sub _GetIssuingRule {
  my ( $categorycode, $itemtype, $holdingbranch ) = @_;

  my $issuingrule = _CheckForIssuingRule( $categorycode, $itemtype, $holdingbranch );
  if ( $issuingrule ) { return $issuingrule; }

  my $issuingrule = _CheckForIssuingRule( $categorycode, '', $holdingbranch );
  if ( $issuingrule ) { return $issuingrule; }

  my $issuingrule = _CheckForIssuingRule( '', $itemtype, $holdingbranch );
  if ( $issuingrule ) { return $issuingrule; }

  my $issuingrule = _CheckForIssuingRule( '', '', $holdingbranch );
  if ( $issuingrule ) { return $issuingrule; }

  my $issuingrule = _CheckForIssuingRule( '', '', '' );
  return $issuingrule;

}

## Checks to see if there is an issuing rule for the given criteria
## $categorycode and/or $itemtype can be empty to indicate wildcard
## $holdingbranch is the current holdingbranch for the item
## If the issuingrule exists, it returns a hashref for it, if not, it returns 0
sub _CheckForIssuingRule {
  my ( $categorycode, $itemtype, $branchcode ) = @_;

warn "C4::FinesOnReturn::_CheckForIssuingRule( \$categorycode = $categorycode, \$itemtype = $itemtype, \$branchcode = $branchcode )";

  if ( ! $categorycode ) { $categorycode = "*"; }
  if ( ! $itemtype ) { $itemtype = "*"; }
  if ( ! $branchcode ) { $branchcode = "*"; }

  my $dbh = C4::Context->dbh;

  my $sql = "SELECT * FROM issuingrules WHERE categorycode LIKE ? AND itemtype LIKE ? AND branchcode LIKE ?";
warn "C4::FinesOnReturn::_CheckForIssuingRule: SELECT * FROM issuingrules WHERE categorycode LIKE '$categorycode' AND itemtype LIKE '$itemtype' AND branchcode LIKE '$branchcode'";
  my $sth = $dbh->prepare( $sql );

  $sth->execute( $categorycode, $itemtype, $branchcode );

  my $issuingrule = $sth->fetchrow_hashref();

if ( $issuingrule ) {
  warn "C4::FinesOnReturn::_CheckForIssuingRule: Found Issuing Rule: ";
  for my $key ( keys %$issuingrule ) {
    warn "C4::FinesOnReturn::_CheckForIssuingRule: $key => " . $issuingrule->{"$key"};
  }
} else {
  warn "C4::FinesOnReturn::_CheckForIssuingRule: No Issuing Rule Found";
}

  return $issuingrule;
}

## Takes a starting and ending date
## in the format YYYY-MM-DD
## and returns the number of
## holidays between the two dates
sub _GetHolidaysBetween {
  my ( $startDate, $endDate, $branchcode ) = @_;

  my ( $sYear, $sMonth, $sDay ) = split( /-/, $startDate );
  my ( $eYear, $eMonth, $eDay ) = split( /-/, $endDate );

  my $holidaysCount = 0;

  my $calendar = C4::Calendar->new( branchcode => $branchcode );

  $holidaysCount += $calendar->isHoliday( $sDay, $sMonth, $sYear );

  while ( mktime( 0, 0, 0, $sDay, $sMonth - 1, $sYear - 1900, 0, 0 ) < mktime( 0, 0, 0, $eDay, $eMonth - 1, $eYear - 1900, 0, 0 ) ) { ## Changed <= to < to fix fine issue
    ( $sYear, $sMonth, $sDay ) = Add_Delta_Days( $sYear, $sMonth, $sDay, 1 );
    $holidaysCount += $calendar->isHoliday( $sDay, $sMonth, $sYear );
  }

  return $holidaysCount;
}

1;
__END__

=back

=head1 AUTHOR

Kyle Hall

=cut
