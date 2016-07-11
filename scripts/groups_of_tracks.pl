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

use EGTH::TrackHub;
use EGTH::TrackHub::Genome;
use EGTH::TrackHub::Track;

use RNAseqDB::DB;
use Log::Log4perl qw( :easy );
Log::Log4perl->easy_init($WARN);
my $logger = get_logger();

###############################################################################
# MAIN
# Get command line args
my %opt = %{ opt_check() };

# Connect to the database schema
my $db = RNAseqDB::DB->connect(
  "dbi:mysql:host=$opt{host}:port=$opt{port}:database=$opt{db}",
  $opt{user},
  $opt{password}
);

# Retrieve track groups
if (defined $opt{output}) {
  my $groups = $db->get_track_groups_for_solr({
      species     => $opt{species},
      files_dir   => $opt{files_dir},
    });
  if (@$groups == 0) {
    die "No group to extract";
  }

  open my $OUT, '>', $opt{output};
  my $json = JSON->new;
  $json->allow_nonref;  # Keep undef values as null
  $json->canonical;     # order keys
  $json->pretty;        # Beautify
  print $OUT $json->encode($groups) . "\n";
  close $OUT;
  
} elsif (defined $opt{hub_root}) {
  my $groups = $db->get_track_groups({
      species     => $opt{species},
      files_dir   => $opt{files_dir},
    });
  
  # Create a trackhub for each group
  create_trackhubs($groups, $opt{hub_root});
}

###############################################################################
# SUB
# Trackhubs creation
sub create_trackhubs {
  my ($groups, $dir) = @_;
  
  GROUP: for my $group (@$groups) {
    # Create the TrackHub
    my $hub = EGTH::TrackHub->new(
      id          => $group->{trackhub_id},
      shortLabel  => $group->{label} // $group->{id},
      longLabel   => $group->{description} // $group->{label} // $group->{id},
    );
    
    my $species_dir = $dir . '/' . $group->{production_name};
    make_path $species_dir;
    $hub->root_dir( $species_dir );
    
    # Create the associated genome
    my $genome = EGTH::TrackHub::Genome->new(
      id      => $group->{assembly},
    );
    
    # Add all tracks to the genome
    my @big_tracks;
    my @bam_tracks;
    TRACK: for my $track (@{ $group->{tracks} }) {
      # Get the bigwig file
      my $bigwig = get_file($track, 'bigwig');
      if (not $bigwig) {
        warn "No bigwig file for this track $track->{id}";
        next TRACK;
      }
      
      my $big_track = EGTH::TrackHub::Track->new(
        track       => $track->{id} . '_bigwig',
        shortLabel  => ($track->{title} // $track->{id}),
        longLabel   => ($track->{description} // $track->{id}),
        bigDataUrl  => $bigwig->{url},
        type        => 'bigWig',
        visibility  => 'full',
      );
      
      push @big_tracks, $big_track;
      
      # Get the bam file
      my $bam = get_file($track, 'bam');
      if (not $bam) {
        warn "No bam file for this track $track->{id}";
        next TRACK;
      }
      
      my $bam_track = EGTH::TrackHub::Track->new(
        track       => $track->{id} . '_bam',
        shortLabel  => ($track->{title} // $track->{id}) . " (bam)",
        longLabel   => ($track->{description} // $track->{id}) . " (bam file)",
        bigDataUrl  => $bam->{url},
        type        => 'bam',
        visibility  => 'hide',
      );
      
      push @bam_tracks, $bam_track;
    }
    
    if (@big_tracks == 0) {
      carp "No track can be used for this group $group->{id}: skip";
      next GROUP;
    } elsif (@big_tracks == 1) {
      $genome->add_track($big_tracks[0]);
      $genome->add_track($bam_tracks[0]);
    } else {
      # Put all that in a supertrack
      $genome->add_track($big_tracks[0]); # Deactivated for now
      $genome->add_track($bam_tracks[0]); # Deactivated for now
    }
    
    # Add the genome...
    $hub->add_genome($genome);
    
    # And create the trackhub files
    $hub->create_files;
  }
}

sub get_file {
  my ($track, $type) = @_;
  
  for my $file (@{ $track->{files} }) {
    if ($file->{type} eq $type) {
      return $file;
    }
  }
  return;
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
    This script exports groups of tracks.

    Database connection:
    --host    <str>   : host name
    --port    <int>   : port
    --user    <str>   : user name
    --password <str>  : password
    --db <str>        : database name
    
    Tracks filter:
    --species <str>   : only outputs tracks for a given species (production_name)
    
    The script can output the groups in json format or create track hubs.
    
    JSON OUTPUT
    --output <path>   : path to the output file in json
    
    TRACK HUBS
    --hub_root      <path> : root where the trackhubs will be created
    --create_hubs   : create the register files
    
    --registry_user <str> : Track Hub Registry user name
    --registry_pass <str> : Track Hub Registry password
    
    Other parameters:
    -files_dir        : root dir to use for the files paths
    
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
    "registry=s",
    "species=s",
    "files_dir=s",
    "output=s",
    "hub_root=s",
    "register_user=s",
    "register_pass=s",
    "help",
    "verbose",
    "debug",
  ) or usage();

  usage()                if $opt{help};
  usage("Need --host")   if not $opt{host};
  usage("Need --port")   if not $opt{port};
  usage("Need --user")   if not $opt{user};
  usage("Need --db")     if not $opt{db};
  usage("Need --output or --hub_root") if (not $opt{output} and not $opt{hub_root});
  $opt{password} //= '';
  Log::Log4perl->easy_init($INFO) if $opt{verbose};
  Log::Log4perl->easy_init($DEBUG) if $opt{debug};
  return \%opt;
}

__END__

