#!/usr/bin/env perl

use 5.10.0;
use strict;
use warnings;
use Readonly;
use Carp;
use autodie qw(:all);
use English qw( -no_match_vars );
use Getopt::Long qw(:config no_ignore_case);
use JSON;
use Perl6::Slurp;
use List::Util qw( first );
use File::Spec qw(cat_file);
use File::Path qw(make_path);
use File::Copy;
use Data::Dumper;
use HTML::Strip;

use aliased 'Bio::EnsEMBL::RNAseqDB';

use Log::Log4perl qw( :easy );
Log::Log4perl->easy_init($WARN);
my $logger = get_logger();

Readonly my %allowed_type_category => (
  bigwig => 'RNAseq',
  bam    => 'BAM',
  cram   => 'CRAM',
);

###############################################################################
# MAIN
# Get command line args
my %opt = %{ opt_check() };

# Connect to the database schema
my $db = RNAseqDB->connect(
  "dbi:mysql:host=$opt{host}:port=$opt{port}:database=$opt{db}",
  $opt{user},
  $opt{password}
);

# Retrieve track bundles
$logger->info("Retrieve tracks informations");
my $bundles = $db->get_bundles({
    species     => $opt{species},
    files_url   => $opt{files_url},
});

my @metatracks = convert_for_Webapollo(@$bundles);
for my $metatrack (@metatracks) {
  my $track = $metatrack->{track};
  my $species = $metatrack->{production_name};
  my $file_dir = $opt{output_dir} . '/' . $species;
  make_path $file_dir;
  my $output_path = $file_dir . '/' . $metatrack->{file_name} . '.json' ;
  print_json($output_path, $track);
}

###############################################################################
# SUB

sub convert_for_Webapollo {
  my @bundles = @_;

  my @tracks;
  
  my $ng = @bundles;
  $logger->debug("($ng groups)");

  # Alter the structure and names to create a valid Solr json for indexing
  for my $group (@bundles) {
    my $nt = @{ $group->{tracks} };
    $logger->debug("Group = $group->{trackhub_id} ($nt tracks)");
    foreach my $track (@{ $group->{tracks} }) {
      my $nf = @{ $track->{files} };
      $logger->debug("Track = $track->{id} ($nf files)");
      FILE: foreach my $file (@{ $track->{files} }) {
        next FILE if not $allowed_type_category{ $file->{type} };
        
        my %track_data = (
          label     => $track->{title},
        );
        
        # Guess the SRA source
        my ($accession_type, $source);
        my $study = $track->{studies}->[0];
        if ($study =~ /^VB/) {
          $source = 'VectorBase website';
          $accession_type = 'VB_study_accession';
        } elsif ($study =~ /^E/) {
          $accession_type = 'ERA_study_accession';
        } elsif ($study =~ /^D/) {
          $accession_type = 'DRA_study_accession';
        } else {
          $accession_type = 'SRA_study_accession';
        }

        my %metadata = (
          $accession_type     => join(', ', @{ $track->{studies} }),
          caption             => $track_data{label},
          category            => $allowed_type_category{ $file->{type} },
          display             => 'off',
          description         => $track->{description},
          version             => $group->{assembly},
          source_url          => $file->{url},
          source_type         => $file->{type},
          source              => $source // $track->{merge_text},
        );
        $metadata{pubmed}      = join(', ', @{ $group->{publications_pubmeds} }) if @{ $group->{publications_pubmeds} };
        $metadata{description} =~ s/(<br>.*)?( ?Merged )?RNA-seq data from.+$//;
        $metadata{description} ||= $track_data{label};
        $metadata{description} = "$metadata{$accession_type} $metadata{description}";
        my $abbrev = @{ $group->{publications_abbrevs} } ? join(', ',  @{ $group->{publications_abbrevs} }) : '';
        $metadata{description} .= " ($abbrev)" if $abbrev;
        $metadata{source}      =~ s/_/, /g;
        
        # Strip any HTML-like tags
        my $hstripper             = HTML::Strip->new();
        $metadata{description} = $hstripper->parse( $metadata{description} );
        $hstripper->eof;

        $track_data{metadata} = \%metadata;
        my %metatrack = (
          production_name => $group->{production_name},
          track           => \%track_data,
          file_name       => $file->{name}
        );
        push @metatracks, \%metatrack;
      }
    }
  }
  return @metatracks;
}

sub print_json {
  my ($output, $data) = @_;
  
  open my $OUT, '>', $output;
  my $json = JSON->new;
  $json->utf8;
  $json->allow_nonref;  # Keep undef values as null
  $json->canonical;     # order keys
  $json->pretty;        # Beautify
  print $OUT $json->encode($data) . "\n";
  close $OUT;
}

###############################################################################
# Parameters and usage
# Print a simple usage note
sub usage {
  my $error = shift;
  my $help = '';
  if ($error) {
    $help = "[ $error ]\n";
  }
  $help .= <<'EOF';
    This script exports tracks in json files for Webapollo.

    Database connection:
    --host    <str>   : host name
    --port    <int>   : port
    --user    <str>   : user name
    --password <str>  : password
    --db <str>        : database name
    
    Filter:
    --species <str>   : filter outputs tracks for a given species (production_name)
    
    Json output:
    --files_url <path>: root url to use for the files paths
    --output <path>   : path to the output directory where the files in json will be created
    
    Other:
    --help            : show this help message
    --verbose         : show detailed progress
    --debug           : show even more information (for debugging purposes)
EOF
  print STDERR "$help\n";
  exit(1);
}

# Get the command-line arguments and check for the mandatory ones
sub opt_check {
  my %opt = ();
  GetOptions(\%opt,
    "host=s",
    "port=i",
    "user=s",
    "password=s",
    "db=s",
    "species=s",
    "files_url=s",
    "output_dir=s",
    "help",
    "verbose",
    "debug",
  ) or usage();

  usage()                if $opt{help};
  usage("Need --host")   if not $opt{host};
  usage("Need --port")   if not $opt{port};
  usage("Need --user")   if not $opt{user};
  usage("Need --db")     if not $opt{db};
  usage("Need --files_url") if not $opt{files_url};
  usage("Need --output_dir") if not $opt{output_dir};
  $opt{password} //= '';
  Log::Log4perl->easy_init($INFO) if $opt{verbose};
  Log::Log4perl->easy_init($DEBUG) if $opt{debug};
  return \%opt;
}

__END__

