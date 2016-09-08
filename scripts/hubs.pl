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

use aliased 'Bio::EnsEMBL::TrackHub::Hub';
use aliased 'Bio::EnsEMBL::TrackHub::Hub::Genome';
use aliased 'Bio::EnsEMBL::TrackHub::Hub::Track';
use aliased 'Bio::EnsEMBL::TrackHub::Hub::SuperTrack';
use aliased 'Bio::EnsEMBL::TrackHub::Registry';

use Bio::EnsEMBL::RNAseqDB;
use Log::Log4perl qw( :easy );
Log::Log4perl->easy_init($WARN);
my $logger = get_logger();

###############################################################################
# MAIN
# Get command line args
my %opt = %{ opt_check() };

# Connect to the database schema
my $db = Bio::EnsEMBL::RNAseqDB->connect(
  "dbi:mysql:host=$opt{host}:port=$opt{port}:database=$opt{db}",
  $opt{user},
  $opt{password}
);

# Retrieve the data (but only if we need it)
my ($groups, $hubs);
if (
       $opt{create}
    or $opt{register}
    or $opt{delete}
    or $opt{public_hubs}
    or $opt{private_hubs}
    or $opt{list_db}
    or $opt{list_diff}
) {
  $logger->info("Retrieving the track bundles...");
  $groups = $db->get_bundles({
      species     => $opt{species},
      files_dir   => $opt{files_dir},
    });

  # Create trackhub objects
  $hubs = prepare_hubs($groups, \%opt);
}

my $registry;
if ($opt{reg_user} and $opt{reg_pass}) {
  $registry = Registry->new(
    user     => $opt{reg_user},
    password => $opt{reg_pass},
  );
}

# Perform actions
create_hubs($hubs)  if $opt{create};
list_db_hubs($hubs) if $opt{list_db};
if ($registry) {
  $registry->is_public(1) if $opt{public_hubs};
  $registry->is_public(0) if $opt{private_hubs};
  if ($opt{register} or $opt{public_hubs} or $opt{private_hubs}) {
    $registry->register_track_hubs(@$hubs);
  }
  delete_hubs($registry, $hubs, \%opt) if $opt{delete};
  
  list_reg_hubs($registry)      if $opt{list_registry};
  diff_hubs($registry, $hubs)   if $opt{list_diff};
}

###############################################################################
# SUB
# Trackhubs creation
sub prepare_hubs {
  my ($groups, $opt) = @_;
  my $dir    = $opt->{hub_root};
  
  croak "Need directory where the hubs would be placed" if not defined $dir;
  croak "Email needed" if not $opt->{email};
  
  my @hubs;
  GROUP: for my $group (@$groups) {
    if (not $group->{assembly} and not $group->{assembly_accession}) {
      print STDERR "No Assembly information for hub $group->{trackhub_id}\n";
      next GROUP;
    }
    
    # Create the TrackHub
    my $hub = Hub->new(
      id          => $group->{trackhub_id},
      shortLabel  => $group->{label} // $group->{id},
      longLabel   => $group->{description} // $group->{label} // $group->{id},
      email       => $opt{email},
    );
    
    # Set the server for this hub to create a valid path to the hub.txt
    my $server = $opt->{hub_server};
    if ($server) {
      $server .= '/' . $group->{production_name};
      $hub->server_dir($server);
    }
    
    my $species_dir = $dir . '/' . $group->{production_name};
    make_path $species_dir;
    $hub->root_dir( $species_dir );
    
    # Create the associated genome
    my $genome = Genome->new(
      id    => $group->{assembly},
      insdc => $group->{assembly_accession},
    );
    
    # Add all tracks to the genome
    my @big_tracks;
    my @bam_tracks;
    TRACK: for my $track (sort { $a->{id} cmp $b->{id} } @{ $group->{tracks} }) {
      # Get the bigwig file
      my $bigwig = get_file($track, 'bigwig');
      if (not $bigwig) {
        warn "No bigwig file for this track $track->{id}";
        next TRACK;
      }
      
      my $big_track = Track->new(
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
      
      my $bam_track = Track->new(
        track       => $track->{id} . '_bam',
        shortLabel  => ($track->{title} // $track->{id}),
        longLabel   => ($track->{description} // $track->{id}),
        bigDataUrl  => $bam->{url},
        type        => 'bam',
        visibility  => 'hide',
      );
      
      push @bam_tracks, $bam_track;
    }
    
    if (@big_tracks == 0) {
      carp "No track can be used for this group $group->{id}: skip";
      next GROUP;
      #} elsif (@big_tracks == 1) {
      #$genome->add_track($big_tracks[0]);
      #$genome->add_track($bam_tracks[0]);
    } else {
      my $superbig = SuperTrack->new(
        track      => $hub->{id} . '_bigwig',
        shortLabel => 'Signal density (bigwig)',
        longLabel  => 'Signal density (bigwig)',
        type       => 'bigWig',
        show       => 1,
      );
      my $superbam = SuperTrack->new(
        track      => $hub->{id} . '_bam',
        shortLabel => 'Reads (bam)',
        longLabel  => 'Reads (bam)',
        type       => 'bam',
        show       => 0,
      );
      # Put all that in a supertrack
      my $n = 0;
      for my $big (@big_tracks) {
        $big->visibility('hide') if $n >= 10;
        $superbig->add_sub_track($big);
        $n++;
      }
      for my $bam (@bam_tracks) {
        $superbam->add_sub_track($bam);
      }
      $genome->add_track($superbig);
      $genome->add_track($superbam);
    }
    
    # Add the genome...
    $hub->add_genome($genome);
    
    # And create the trackhub files
    push @hubs, $hub;
  }
  return \@hubs;
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

sub create_hubs {
  my ($hubs) = @_;
  
  my $num_hubs = @$hubs;
  $logger->info("Creating files for $num_hubs track hubs");
  for my $hub (@$hubs) {
    $hub->create_files;
  }
}

sub delete_hubs {
  my ($registry, $hubs, $opt) = @_;
  
  if ($opt->{species}) {
    my $n = @$hubs;
    $logger->info("Deleting $n track hubs for species $opt->{species}");
    $registry->delete_track_hubs(@$hubs);
  } else {
    $logger->info("Deleting all track hubs in the registry");
    $registry->delete_all_track_hubs;
  }
}

sub toggle_hubs {
  my ($hubs, $opt) = @_;
  
  my $public = $opt{public_hubs} ? 1 : 1;
  for my $hub (@$hubs) {
    $hub->public($public);
    $hub->update($opt{user}, $opt{password});
  }
}

sub get_list_db_hubs {
  my ($hubs) = @_;
  
  my @hub_ids;
  foreach my $hub (@$hubs) {
    push @hub_ids, $hub->id;
  }
  return @hub_ids;
}

sub list_db_hubs {
  my ($hubs) = @_;
  
  my @db_hubs = get_list_db_hubs($hubs);
  my $num_hubs = @db_hubs;
  print "$num_hubs track hubs in the RNAseqDB\n";
  for my $hub_id (@db_hubs) {
    print "$hub_id\n";
  }
}

sub list_reg_hubs {
  my ($registry, $hubs) = @_;
  
  my @reg_hubs = $registry->get_all_registered();
  my $num_hubs = @reg_hubs;
  print "$num_hubs track hubs registered\n";
  for my $hub_id (@reg_hubs) {
    print "$hub_id\n";
  }
}

sub diff_hubs {
  my ($registry, $hubs) = @_;
  
  my @db_hubs  = get_list_db_hubs($hubs);
  my @reg_hubs = $registry->get_registered();
  
  my %db_hub_hash  = map { $_ => 1 } @db_hubs;
  my %reg_hub_hash = map { $_->{name} => 1 } @reg_hubs;
  my @common;
  for my $reg_hub_id (keys %reg_hub_hash) {
    if (exists $db_hub_hash{$reg_hub_id}) {
      push @common, $reg_hub_id;
      delete $reg_hub_hash{$reg_hub_id};
      delete $db_hub_hash{$reg_hub_id};
    }
  }
  
  # Print summary
  my @db_only  = sort keys %db_hub_hash;
  my @reg_only = sort keys %reg_hub_hash;
  print sprintf "%d trackhubs from the RNAseq DB are registered\n", ''.@common;
  print sprintf "%d trackhubs are only in the RNAseq DB\n", ''.@db_only if @db_only > 0;
  print sprintf "%d trackhubs are only in the Registry\n", ''.@reg_only if @reg_only > 0;
  
  for my $hub_id (@db_only) {
    print "Only in the RNAseqDB: $hub_id\n";
  }
  for my $hub_id (@reg_only) {
    print "Only in the Registry: $hub_id\n";
  }
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
    This script creates and registers track hubs from an RNAseqDB.

    RNASEQDB CONNECTION
    --host    <str>   : host name
    --port    <int>   : port
    --user    <str>   : user name
    --password <str>  : password
    --db <str>        : database name
    
    
    TRACK HUBS
    -files_dir        : root dir to use for the files paths
                        (used in the Trackdb.txt files)
    --hub_root <path> : root where the trackhubs should be stored
    
    
    ACTIONS (at least one of them is needed)
    
    Create:
    --create          : create the hub files
    
    Register:
    --register        : register the hub files
                        (the hub files must exist)
    --hub_server <str>: http/ftp address to the root of the hub files
    --reg_user <str>  : Track Hub Registry user name
    --reg_pass <str>  : Track Hub Registry password
    
    Delete:
    --delete          : delete all trackhubs from the registry
                        (not the files themselves)
    
    Show/hide:
    --public_hubs     : set all tracks as public
                        (can be searched in the Registry)
    --private_hubs    : set all tracks as private
                        (can't be searched in the Registry)
    
    NB: by default all track hubs are registered as private
    
    List:
    --list_db         : list the trackhubs from the RNAseqDB
    --list_registry   : list the trackhubs from the Registry
    --list_diff       : compare the trackhubs from the RNAseqDB
                        and from the Registry
    
    OTHER
    --species <str>   : only outputs tracks for a given species
                        (production_name)
    --help            : show this help message
    --verbose         : show detailed progress
    --debug           : show even more information
                        (for debugging purposes)
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
    "hub_root=s",
    "email=s",
    "create",
    "register",
    "reg_user=s",
    "reg_pass=s",
    "hub_server=s",
    "delete",
    "public_hubs",
    "private_hubs",
    "list_db",
    "list_registry",
    "list_diff",
    "help",
    "verbose",
    "debug",
  ) or usage();

  usage()                if $opt{help};
  usage("Need --host")   if not $opt{host};
  usage("Need --port")   if not $opt{port};
  usage("Need --user")   if not $opt{user};
  usage("Need --db")     if not $opt{db};
  usage("Need --hub_root") if not $opt{hub_root};
  $opt{password} //= '';
  usage("Need registry user and password") if ($opt{register} or $opt{delete} or $opt{public_hubs} or $opt{private_hubs} or $opt{list_registry} or $opt{list_diff}) and not ($opt{reg_user} and $opt{reg_pass});
  usage("Need hub server") if $opt{register} and not $opt{hub_server};
  usage("Select public XOR private") if ($opt{public_hubs} and $opt{private_hubs});
  Log::Log4perl->easy_init($INFO) if $opt{verbose};
  Log::Log4perl->easy_init($DEBUG) if $opt{debug};
  return \%opt;
}

__END__

