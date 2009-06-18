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

use CGI;
use strict;
use C4::Auth;
use C4::Output;
use C4::Biblio;
use C4::Items;
use C4::Context;
use C4::Koha; # XXX subfield_is_koha_internal_p
use C4::Branch; # XXX subfield_is_koha_internal_p
use C4::ClassSource;
use C4::Dates;
use C4::Form::AddItem;

use MARC::File::XML;

my $input = new CGI;
my $dbh = C4::Context->dbh;
my $error        = $input->param('error');
my $biblionumber = $input->param('biblionumber');
my $itemnumber   = $input->param('itemnumber');
my $op           = $input->param('op');

my ($template, $loggedinuser, $cookie)
    = get_template_and_user({template_name => "cataloguing/additem.tmpl",
                 query => $input,
                 type => "intranet",
                 authnotrequired => 0,
                 flagsrequired => {editcatalogue => 1},
                 debug => 1,
                 });

my $frameworkcode = &GetFrameworkCode($biblionumber);

my $today_iso = C4::Dates->today('iso');
$template->param(today_iso => $today_iso);

my $tagslib = &GetMarcStructure(1,$frameworkcode);
my $record = GetMarcBiblio($biblionumber);
my $oldrecord = TransformMarcToKoha($dbh,$record);
my $itemrecord;
my $nextop="additem";
my @errors; # store errors found while checking data BEFORE saving item.
#-------------------------------------------------------------------------------
if ($op eq "additem") {
#-------------------------------------------------------------------------------
    # rebuild
    my @tags      = $input->param('tag');
    my @subfields = $input->param('subfield');
    my @values    = $input->param('field_value');
    # build indicator hash.
    my @ind_tag   = $input->param('ind_tag');
    my @indicator = $input->param('indicator');
    my $xml = TransformHtmlToXml(\@tags,\@subfields,\@values,\@indicator,\@ind_tag, 'ITEM');
    my $record = MARC::Record::new_from_xml($xml, 'UTF-8');
    # if autoBarcode is set to 'incremental', calculate barcode...
	# NOTE: This code is subject to change in 3.2 with the implemenation of ajax based autobarcode code
	# NOTE: 'incremental' is the ONLY autoBarcode option available to those not using javascript
    if (C4::Context->preference('autoBarcode') eq 'incremental') {
        my ($tagfield,$tagsubfield) = &GetMarcFromKohaField("items.barcode",$frameworkcode);
        unless ($record->field($tagfield)->subfield($tagsubfield)) {
            my $sth_barcode = $dbh->prepare("select max(abs(barcode)) from items");
            $sth_barcode->execute;
            my ($newbarcode) = $sth_barcode->fetchrow;
            $newbarcode++;
            # OK, we have the new barcode, now create the entry in MARC record
            my $fieldItem = $record->field($tagfield);
            $record->delete_field($fieldItem);
            $fieldItem->add_subfields($tagsubfield => $newbarcode);
            $record->insert_fields_ordered($fieldItem);
        }
    }
# check for item barcode # being unique
    my $addedolditem = TransformMarcToKoha($dbh,$record);
    my $exist_itemnumber = get_item_from_barcode($addedolditem->{'barcode'});
    push @errors,"barcode_not_unique" if($barcode_not_unique);
    # if barcode exists, don't create, but report The problem.
    my ($oldbiblionumber,$oldbibnum,$oldbibitemnum) = AddItemFromMarc($record,$biblionumber) unless ($exist_itemnumber);
    $nextop = "additem";
    if ($exist_itemnumber) {
        $itemrecord = $record;
    }
#-------------------------------------------------------------------------------
} elsif ($op eq "edititem") {
#-------------------------------------------------------------------------------
# retrieve item if exist => then, it's a modif
    $itemrecord = C4::Items::GetMarcItem($biblionumber,$itemnumber);
    $nextop = "saveitem";
#-------------------------------------------------------------------------------
} elsif ($op eq "delitem") {
#-------------------------------------------------------------------------------
    # check that there is no issue on this item before deletion.
    my $sth=$dbh->prepare("select * from issues i where i.itemnumber=?");
    $sth->execute($itemnumber);
    my $onloan=$sth->fetchrow;
	$sth->finish();
    $nextop="additem";
    if ($onloan){
        push @errors,"book_on_loan";
    } else {
		# check it doesnt have a waiting reserve
		$sth=$dbh->prepare("SELECT * FROM reserves WHERE found = 'W' AND itemnumber = ?");
		$sth->execute($itemnumber);
		my $reserve=$sth->fetchrow;
		unless ($reserve){
			&DelItem($dbh,$biblionumber,$itemnumber);
			print $input->redirect("additem.pl?biblionumber=$biblionumber&frameworkcode=$frameworkcode");
            exit;
		}
        push @errors,"book_reserved";
    }
#-------------------------------------------------------------------------------
} elsif ($op eq "saveitem") {
#-------------------------------------------------------------------------------
    # rebuild
    eval { $itemtosave = C4::Form::AddItem::get_item_record($input, 0, $itemnumber); };
    if ($@) {
        chomp $@;
        die $@ if ( $@ !~ /^[a-z0-9_]+$/ );
        push @errors, $@;
    } else {
        my ($oldbiblionumber,$oldbibnum,$oldbibitemnum) = ModItemFromMarc($itemtosave,$biblionumber,$itemnumber);
        $itemnumber="";
    }
    $nextop="additem";
}

#
#-------------------------------------------------------------------------------
# build screen with existing items. and "new" one
#-------------------------------------------------------------------------------

# now, build existiing item list
my $temp = GetMarcBiblio( $biblionumber );
my @fields = $temp->fields();
#my @fields = $record->fields();
my %witness; #---- stores the list of subfields used at least once, with the "meaning" of the code
my @big_array;
#---- finds where items.itemnumber is stored
my (  $itemtagfield,   $itemtagsubfield) = &GetMarcFromKohaField("items.itemnumber", $frameworkcode);
my ($branchtagfield, $branchtagsubfield) = &GetMarcFromKohaField("items.homebranch", $frameworkcode);

foreach my $field (@fields) {
    next if ($field->tag()<10);
    my @subf = $field->subfields;
    (defined @subf) or @subf = ();
    my %this_row;
# loop through each subfield
    for my $i (0..$#subf) {
        next if ($tagslib->{$field->tag()}->{$subf[$i][0]}->{tab} ne 10 
                && ($field->tag() ne $itemtagfield 
                && $subf[$i][0]   ne $itemtagsubfield));

        $witness{$subf[$i][0]} = $tagslib->{$field->tag()}->{$subf[$i][0]}->{lib} if ($tagslib->{$field->tag()}->{$subf[$i][0]}->{tab}  eq 10);
		if ($tagslib->{$field->tag()}->{$subf[$i][0]}->{tab}  eq 10) {
        	$this_row{$subf[$i][0]}=GetAuthorisedValueDesc( $field->tag(),
                        $subf[$i][0], $subf[$i][1], '', $tagslib) 
						|| $subf[$i][1];
		}

        if (($field->tag eq $branchtagfield) && ($subf[$i][$0] eq $branchtagsubfield) && C4::Context->preference("IndependantBranches")) {
            #verifying rights
            my $userenv = C4::Context->userenv();
            unless (($userenv->{'flags'} == 1) or (($userenv->{'branch'} eq $subf[$i][1]))){
                    $this_row{'nomod'}=1;
            }
        }
        $this_row{itemnumber} = $subf[$i][1] if ($field->tag() eq $itemtagfield && $subf[$i][0] eq $itemtagsubfield);
    }
    if (%this_row) {
        push(@big_array, \%this_row);
    }
}

my ($holdingbrtagf,$holdingbrtagsubf) = &GetMarcFromKohaField("items.holdingbranch",$frameworkcode);
@big_array = sort {$a->{$holdingbrtagsubf} cmp $b->{$holdingbrtagsubf}} @big_array;

# now, construct template !
# First, the existing items for display
my @item_value_loop;
my @header_value_loop;
for my $row ( @big_array ) {
    my %row_data;
    my @item_fields = map +{ field => $_ || '' }, @$row{ sort keys(%witness) };
    $row_data{item_value} = [ @item_fields ];
    $row_data{itemnumber} = $row->{itemnumber};
    #reporting this_row values
    $row_data{'nomod'} = $row->{'nomod'};
    push(@item_value_loop,\%row_data);
}
foreach my $subfield_code (sort keys(%witness)) {
    my %header_value;
    $header_value{header_value} = $witness{$subfield_code};
    push(@header_value_loop, \%header_value);
}

# now, build the item form for entering a new item

# what's the next op ? it's what we are not in : an add if we're editing, otherwise, and edit.
$template->param( title => $record->title() ) if ($record ne "-1");
$template->param(
    biblionumber => $biblionumber,
    title        => $oldrecord->{title},
    author       => $oldrecord->{author},
    item_loop        => \@item_value_loop,
    item_header_loop => \@header_value_loop,
    item             => C4::Form::AddItem::get_form_values( $itemrecord, 0 ),
    itemnumber       => $itemnumber,
    itemtagfield     => $itemtagfield,
    itemtagsubfield  => $itemtagsubfield,
    op      => $nextop,
    opisadd => ($nextop eq "saveitem") ? 0 : 1,
);
foreach my $error (@errors) {
    $template->param($error => 1);
}
output_html_with_http_headers $input, $cookie, $template->output;
