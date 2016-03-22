use utf8;
package RNAseqDB::SRA;
use Moose::Role;

use strict;
use warnings;
use List::Util qw( first );
use JSON;
use Perl6::Slurp;
use Log::Log4perl qw( :easy );

my $logger = get_logger();
use Data::Dumper;
use Readonly;
use Try::Tiny;

use Bio::EnsEMBL::ENA::SRA::BaseSraAdaptor qw(get_adaptor);

# Patterns to discriminate between the different SRA elements
my Readonly $STUDY_REGEX      = qr{[SED]RP\d+};
my Readonly $EXPERIMENT_REGEX = qr{[SED]RX\d+};
my Readonly $RUN_REGEX        = qr{[SED]RR\d+};
my Readonly $SAMPLE_REGEX     = qr{[SED]RS\d+};

my Readonly $PRIVATE_PREFIX    = 'VBSR';
my Readonly $STUDY_PREFIX      = $PRIVATE_PREFIX . 'S';
my Readonly $EXPERIMENT_PREFIX = $PRIVATE_PREFIX . 'X';
my Readonly $RUN_PREFIX        = $PRIVATE_PREFIX . 'R';
my Readonly $SAMPLE_PREFIX     = $PRIVATE_PREFIX . 'S';

# add_sra     Add all runs related to the given SRA accession to the DB
# Input       string = SRA accession
# Output      int    = number of runs added
sub add_sra {
  my ($self, $sra_acc) = @_;
  
  if ($sra_acc =~ $STUDY_REGEX) {
    return $self->_add_runs_from($sra_acc, 'study');
  }
  elsif ($sra_acc =~ $EXPERIMENT_REGEX) {
    return $self->_add_runs_from($sra_acc, 'experiment');
  }
  elsif ($sra_acc =~ $RUN_REGEX) {
    # Special case: all other cases are wrappers around this
    return $self->_add_run($sra_acc);
  }
  elsif ($sra_acc =~ $SAMPLE_REGEX) {
    return $self->_add_runs_from($sra_acc, 'sample');
  }
  else {
    $logger->warn("WARNING; Invalid SRA accession: $sra_acc");
    return 0;
  }
}

# add_runs_from   generic function to add runs from an SRA item
# Input[1]        string = SRA accession
# Input[2]        string = RNAseqDB table for this SRA item
sub _add_runs_from() {
  my ($self, $acc, $table) = @_;
  
  return 0 if not defined $acc or $acc =~ /^\s*$/;
  
  # Try to get the id if it exists
  my $table_class = ucfirst $table;
  my $key = $table . '_sra_acc';
  my $req = $self->resultset( $table_class )->search({
      $key => $acc,
  });

  my @rows = $req->all;
  my $num = scalar @rows;
  if ($num == 1) {
    $logger->debug("$table " . $acc . " has 1 id already.");
    
    # Stop if trying to insert a run
    if ($table eq 'run') {
      return 0;
    }
  }
 
  # Retrieve data from ENA
  my $adaptor = get_adaptor( $table );
  
  my $sra;
  try {
    ($sra) = @{ $adaptor->get_by_accession($acc) };
  }
  catch {
    $logger->warn("WARNING: Could not retrieve SRA data for $acc");
    return 0;
  };
  
  if (not defined $sra) {
    $logger->warn("$table impossible to get: " . $acc);
    return 0;
  }
  
  # Add each one individually
  my $total = 0;
  for my $run (@{ $sra->runs() }) {
    my $num_inserted = $self->_add_run( $run->accession() );
    $total += $num_inserted;
  }
  return $total;
}

# add_run       Import this run
# Input         SRA run accession
# Output        Number of runs newly inserted in the DB (0 if none)
sub _add_run {
  my ($self, $run_acc) = @_;
  return 0 if not defined $run_acc or $run_acc =~ /^\s*$/;
  
  # Try to get the run id if it exists
  my $run_req = $self->resultset('Run')->search({
      run_sra_acc => $run_acc,
  });

  my @run_rows = $run_req->all;
  my $num_run = scalar @run_rows;
  if ($num_run == 1) {
    $logger->debug("Run " . $run_acc . " has 1 id already.");
    return 0;
  }
  
  # Retrieve run data from ENA
  my $run_adaptor = get_adaptor('Run');
  
  my $run;
  try {
    ($run) = @{ $run_adaptor->get_by_accession($run_acc) };
  }
  catch {
    $logger->warn("WARNING: Could not retrieve SRA data for $run_acc");
    return 0;
  };
  
  if (not defined $run) {
    $logger->warn("Run impossible to get: " . $run_acc);
    return 0;
  }
  
  # Retrieve the experiment and sample ids to create a run
  my $sample_id = $self->_get_sample_id($run->sample());
  if (not defined $sample_id) {
    $logger->warn("Can't insert the run $run_acc: no sample_id returned");
    return 0;
  }
  my $experiment_id = $self->_get_experiment_id($run->experiment());
  my $submitter = $self->_get_run_submitter($run);
  
  if (    defined $experiment_id
      and defined $sample_id) {
    $logger->info("ADDING run " . $run->accession() . "");
    $self->resultset('Run')->create({
        run_sra_acc     => $run->accession(),
        experiment_id   => $experiment_id,
        sample_id       => $sample_id,
        title           => $run->title(),
        submitter       => $submitter,
      });
  } else {
    $logger->warn("An error occured: can't insert the run " . $run_acc);
    return 0;
  }
  
  return 1;
}

sub _get_run_submitter {
  my ($self, $run) = @_;
  
  my $identifiers = $run->identifiers()->{SUBMITTER_ID};
  return $identifiers->{namespace};
}

sub _get_experiment_id {
  my ($self, $experiment) = @_;
  
  # Try to get the experiment id if it exists
  my $exp_req = $self->resultset('Experiment')->search({
      experiment_sra_acc => $experiment->accession()
  });

  my @exp_rows = $exp_req->all;
  my $num_exp = scalar @exp_rows;
  if ($num_exp == 1) {
    $logger->debug("Experiment " . $experiment->accession() . " has 1 id already.");
    return $exp_rows[0]->experiment_id;
  }
  # Error: there should not be more than one row per experiment
  elsif ($num_exp > 1) {
    $logger->warn("Several experiments found with accession " . $experiment->accession());
    return;
  }
  # Last case: we have to add this experiment
  else {
    my $study_id = $self->_get_study_id($experiment->study());
    
    if (defined $study_id) {
      $logger->info("ADDING experiment " . $experiment->accession() . "");
      my $insertion = $self->resultset('Experiment')->create({
          experiment_sra_acc     => $experiment->accession(),
          title                  => $experiment->title(),
          study_id               => $study_id,
        });
      return $insertion->id();
    }
  }
}

sub _get_study_id {
  my ($self, $study) = @_;
  
  # Try to get the study id if it exists
  my $study_req = $self->resultset('Study')->search({
      study_sra_acc => $study->accession()
  });

  my @study_rows = $study_req->all;
  my $num_study = scalar @study_rows;
  if ($num_study == 1) {
    $logger->debug("Study " . $study->accession() . " has 1 id already.");
    return $study_rows[0]->study_id;
  }
  # Error: there should not be more than one row per study
  elsif ($num_study > 1) {
    $logger->warn("Several studies found with accession " . $study->accession());
    return;
  }
  # Last case: we have to add this study
  else {
    $logger->info("ADDING study " . $study->accession() . "");
    my $insertion = $self->resultset('Study')->create({
        study_sra_acc   => $study->accession(),
        title           => $study->title(),
        abstract        => $study->abstract(),
      });
    my $study_id = $insertion->id();
    my @pubmed_links = grep { $_->{XREF_LINK}->{DB} eq 'pubmed' } @{ $study->links() };
    foreach my $pubmed_link (@pubmed_links) {
      my $pubmed_id = $pubmed_link->{XREF_LINK}->{ID};
      $self->_add_study_publication($study_id, $pubmed_id);
    }
    
    return $study_id;
  }
}

sub _get_sample_id {
  my ($self, $sample) = @_;
  
  # Try to get the sample id if it exists
  my $sample_req = $self->resultset('Sample')->search({
      sample_sra_acc => $sample->accession()
  });

  my @sample_rows = $sample_req->all;
  my $num_sample = scalar @sample_rows;
  if ($num_sample == 1) {
    $logger->debug("Sample " . $sample->accession() . " has 1 id already.");
    return $sample_rows[0]->sample_id;
  }
  # Error: there should not be more than one row per sample
  elsif ($num_sample > 1) {
    $logger->warn("Several samples found with accession " . $sample->accession());
    return;
  }
  # Last case: we have to add this sample
  else {
    
    # All is ok? Insert!
    my $attribs_aref = $sample->attributes();
    $attribs_aref = [$attribs_aref] if ref($attribs_aref) eq 'HASH';
    
    # Get strain
    my @strain_attrib = grep {
      lc($_->{TAG}) eq 'strain' and $_->{VALUE} ne 'missing'
    } @$attribs_aref;
    my $strain = join(',', map { $_->{VALUE} } @strain_attrib);
    
    # Get sample label
    my @label_attrib = grep { lc($_->{TAG}) eq 'label' } @$attribs_aref;
    my $label = join(',', map { $_->{VALUE} } @label_attrib);
    
    # Get biosample accession
    my $identifiers_aref = $sample->identifiers()->{EXTERNAL_ID};
    $identifiers_aref = [$identifiers_aref] if not ref($identifiers_aref) eq 'ARRAY';
    my $biosample_href = first { $_->{namespace} eq 'BioSample' } @$identifiers_aref;
    my $biosample_acc = $biosample_href->{content};
    
    # Get taxon_id
    my $taxon_id = $sample->taxon()->taxon_id();
    
    # Get the correct species_id
    my $strain_id = $self->_get_strain_id($taxon_id, $strain);
    
    # No species id? Failed to add
    if (not defined $strain_id) {
      $logger->info("Skip sample because the species ($taxon_id, $strain) could not be found in the species table");
      return;
    }
    
    $logger->info("ADDING sample " . $sample->accession() . "");
    my $insertion = $self->resultset('Sample')->create({
        sample_sra_acc    => $sample->accession(),
        title             => $sample->title(),
        description       => $sample->description(),
        taxon_id          => $taxon_id,
        strain            => $strain,
        strain_id         => $strain_id,
        biosample_acc     => $biosample_acc,
        label             => $label,
      });
    my $sample_id = $insertion->id();
    $self->_add_track($sample_id);
    return $sample_id;
  }
}

sub _add_track {
  my ($self, $sample_id) = @_;
  
  # Does the track already exists?
  my $track_req = $self->resultset('Track')->search({
      'sra_track.sample_id' => $sample_id,
  },
  {
    prefetch    => 'sra_track',
  });

  my @res_tracks = $track_req->all;
  my $num_tracks = scalar @res_tracks;
  if ($num_tracks > 1) {
    $logger->warn("WARNING: Track already exists for sample $sample_id");
    return;
  }
  
  # Insert a new track and a link sra_track
  # NB: the default is a merging at the sample level
  $logger->info("ADDING track for $sample_id");
  
  # Add the track itself
  my $track_insertion = $self->resultset('Track')->create({});
  
  # Add the link from the sample to the track
  my $sra_track_insertion = $self->resultset('SraTrack')->create({
      sample_id    => $sample_id,
      track_id  => $track_insertion->id,
  });
  
  return;
}

#######################################################################################################################
# Private studies
sub add_private_study {
  my ($self, $study_href) = @_;
  
  my $num = 0;
  
  # First, get the study
  my $study = $study_href->{info};
  
  # Insert the study
  my $insert_study = $self->resultset('Study')->create( $study );
  my $study_id = $insert_study->id;
  
  # Insert the pbmed
  my $pubmed_id = $study_href->{pubmed_id};
  $self->_add_study_publication($study_id, $pubmed_id) if defined $pubmed_id;
  
  # Create an accession for this study from its id
  if (not defined $study->{study_private_acc}) {
    $study->{ study_private_acc } = sprintf("%s%d", $STUDY_PREFIX, $study_id);
    
    my $update_study = $self->resultset('Study')->search({
        study_id => $study_id,
      })->update( $study );
      $logger->info("CREATED study $study->{ study_private_acc }");
  }
  
  # Next, insert the samples
  my $samples_aref = $study_href->{samples};
  my %samples_ids = ();
  for my $sample_href (@$samples_aref) {
    my $sample = $sample_href->{info};
    # Make sure we don't insert sample without an id
    my $tax_request = $self->resultset('Taxonomy')->search({
        production_name => $study_href->{production_name},
      });
    my @taxons = $tax_request->all;
    my $num_tax = scalar @taxons;
    if ($num_tax != 1) {
      $logger->warn("WARNING: not just one taxon found ($num_tax)");
      return 0;
    }
    my $taxon = shift @taxons;
    $sample->{taxon_id}  = $taxon->get_column('taxon_id');
    $sample->{strain}    = $taxon->get_column('strain');
    $sample->{strain_id} = $taxon->get_column('strain_id');
    
    # Insert the sample
    my $insert_sample = $self->resultset('Sample')->create( $sample );
    my $sample_id = $insert_sample->id;
    
    # Create an accession for this sample from its id
    if (not defined $sample->{sample_private_acc}) {
      $sample->{ sample_private_acc } = sprintf("%s%d", $SAMPLE_PREFIX, $sample_id);

      my $update_sample = $self->resultset('Sample')->search({
          sample_id => $sample_id,
        })->update( $sample );
      $logger->info("CREATED sample $sample->{ sample_private_acc }");
    }
    
    # Keep the match sample id = sample_name (to link the runs)
    $samples_ids{ $sample_href->{sample_name} } = $sample_id;
  }
  
  # Next, insert the experiments (and runs)
  my $experiments_aref = $study_href->{experiments};
  for my $experiment_href (@$experiments_aref) {
    my $experiment = $experiment_href->{info};
    $experiment->{study_id}  = $study_id;
    
    # Insert the experiment
    my $insert_experiment = $self->resultset('Experiment')->create( $experiment );
    my $experiment_id = $insert_experiment->id;
    
    # Create an accession for this experiment from its id
    if (not defined $experiment->{experiment_private_acc}) {
      $experiment->{ experiment_private_acc } = sprintf("%s%d", $EXPERIMENT_PREFIX, $experiment_id);

      my $update_experiment = $self->resultset('Experiment')->search({
          experiment_id => $experiment_id,
        })->update( $experiment );
      $logger->info("CREATED experiment $experiment->{ experiment_private_acc }");
    }
    
    # Finally, add all the corresponding runs
    my $runs_aref = $experiment_href->{runs};
    my %runs_ids = ();
    for my $run_href (@$runs_aref) {
      my $run = $run_href->{info};
      $run->{sample_id} = $samples_ids{ $run_href->{sample_name} };
      $run->{experiment_id}  = $experiment_id;

      # Insert the run
      my $insert_run = $self->resultset('Run')->create( $run );
      my $run_id = $insert_run->id;

      # Create an accession for this run from its id
      if (not defined $run->{run_private_acc}) {
        $run->{ run_private_acc } = sprintf("%s%d", $RUN_PREFIX, $run_id);

        my $update_run = $self->resultset('Run')->search({
            run_id => $run_id,
          })->update( $run );
        $logger->info("CREATED study $study->{ study_private_acc }");
      }
      $num++;
    }
  }
  return $num;
}

sub add_private_study_from_json {
  my ($self, $json_path) = @_;
  return 0 if not -s $json_path;
  
  my $json = slurp $json_path;
  my $rnaseq_study = decode_json($json);
  
  return $self->add_private_study($rnaseq_study);
}
#######################################################################################################################
# Taxonomy

sub _get_strain_id {
  my ($self, $taxon_id, $strain) = @_;
  $strain ||= '';
  
  my $species_href = $self->_get_strain_ids();
  return if not defined $species_href;
  my $sp_taxons = $species_href->{ $taxon_id };
  
  if (defined $sp_taxons) {
    # First try, with the couple taxon_id and strain
    if(defined $sp_taxons->{ $strain }) {
      return $sp_taxons->{ $strain };
    }

    # Second try: try to find the species.strain name in the sample.strain name
    my @sp_strains = keys %$sp_taxons;
    my @found_sp_strains = ();
    for my $sp_strain (@sp_strains) {
      next if $sp_strain eq '';
      # Can we find the strain name?
      if ($strain =~ /$sp_strain/) {
        push @found_sp_strains, $sp_strain;
      }
    }

    # Found 1 match?
    my $sp_match = scalar @found_sp_strains;
    if ($sp_match == 1) {
      my $sp_strain = $found_sp_strains[0];
      $logger->info("WARNING: Automatically matched the strain $strain to $sp_strain ($sp_taxons->{ $sp_strain })");
      return $sp_taxons->{ $sp_strain };
    }
    elsif ($sp_match > 1) {
      $logger->warn("WARNING: Several species match the strain name: $taxon_id, $strain");
      return;
    }
    else {
      # Last try, match with only the taxon_id
      my @species_id_list = map { $sp_taxons->{$_} } sort keys %$sp_taxons;
      my %species_ids = map { $_ => 1 } @species_id_list;

      # Found only 1 possible species_id for this taxon_id?
      my $sp_ids_match = scalar(keys %species_ids);
      
      if ($sp_ids_match == 1) {
        $logger->info("Matched species: $taxon_id, $strain => $species_id_list[0]");
        return $species_id_list[0];
      }
      # Several possibilities?
      elsif ($sp_ids_match > 1) {
        my $sp_list = join(', ', @species_id_list);
        $logger->warn("WARNING: Several species match the taxon_id: $taxon_id, $strain ($sp_list). Using $species_id_list[0] (please check!)");
        return $species_id_list[0];
        return;
      }
      else {
        $logger->info("Rejected species, strain is not found in the species table: $taxon_id, $strain");
        return;
      }
    }
  }
  else {
    $logger->warn( "WARNING: Taxon_id is not defined in the species table: $taxon_id ($strain)" );
    return;
  }
}

sub _get_strain_ids {
  my $self = shift;
  
  if (not defined $self->{strain_ids}) {
   $self->_load_species(); 
  }
  return $self->{strain_ids};
}

sub _load_species {
  my ($self) = @_;
  
  my $species_req = $self->resultset('Taxonomy')->search({
      status  => 'ACTIVE',
    });
  my @lines = $species_req->all;
  if (@lines == 0) {
    $logger->warn("WARNING: the taxonomy tables appear to be empty");
    return;
  }
  
  my %strain_ids = ();
  
  for my $line (@lines) {
    my $strain = $line->strain;
    $strain ||= '';
    my $taxon_id = $line->taxon_id;
    $taxon_id ||= '';
    $logger->warn("Taxon without taxon_id: " . $line->production_name) if not defined $taxon_id;
    my $key = $taxon_id . '__' . $strain;
    $strain_ids{ $taxon_id }{ $strain } = $line->strain_id;
  }
  
  $self->{strain_ids} = \%strain_ids;
}

1;
__END__

=head1 NAME

RNAseqDB::SRA - Interface for the RNAseq DB.


=head1 VERSION

This document describes RNAseqDB::DB version 0.0.1


=head1 SYNOPSIS

    use RNAseqDB::DB;

    # Connect to an RNAseqDB
    my $rdb = RNAseqDB::DB->connect(
      "dbi:mysql:host=$host:port=$port:database=$db",
      $user,
      $password
    );
    
    # Prepare the species table
    $rdb->add_species('aedes_aegypti', 7159, 'Liverpool');
    
    # Add a study
    $rdb->add_sra('SRP009679');


=head1 DESCRIPTION

This module is an object interface for the RNAseqDB. It inherits the RNAseqDB::Schema object, which is a DBIx class.


The purpose of the interface is to simplify the population of the database.


The module logs with Log4perl (easy mode).

=head1 INTERFACE

=over

=item BUILD connect()

  (Inherited from RNAseqDB::Schema)
  Args           : DBI connection arguments
  Function       : create a connection to an RNAseq DB
  Usage:

    my $rdb = RNAseqDB::DB->connect(
      "dbi:mysql:host=$host:port=$port:database=$db",
      $user,
      $password
    );

=item add_sra()

  Function       : Add all runs from a given SRA study/experiment/sample or run accession.
  Arg[1]         : String: an SRA study/experiment/sample/run accession
  Returntype     : Integer: number of runs newly added.
  Usage:

    $rdb->add_sra('SRP000000');
    $rdb->add_sra('SRX000000');
    $rdb->add_sra('SRR000000');
    $rdb->add_sra('SRS000000');

  NB1: The corresponding species must be present in the species table (see add_species()), otherwise it will be rejected.
  NB2: the runs will not be added if they are already in the database. They will also not be added if they fail to retrieve the corresponding sample and experiment ids.

=item add_private_study()
=item add_private_study_from_json()

  Function       : Add a private study (no SRA) described in a structured data format. In the *_from_json version, the data is imported from a json file: this is the preferred way to insert new data without SRA.
  Arg[1]         : Ref: structured data (or JSON) representing the study, experiment, samples and runs.
  Returntype     : Integer: number of runs newly added.
  Usage:

    $rdb->add_private_study_from_json('private_study1.json');

  The data structure must be as such (json):
  
  {
    "info": {
      "title": "Species xxx RNAseq study",
      "abstract": "Species xxx RNAseq study abstract text"
    },
    "production_name": "species_x",

    "experiments":
      [
      {
        "info": {
          "title": "Species xxx RNAseq experiment"
        },

        "runs": 
          [
          {
            "info": {
              "title": "Species xxx RNAseq run",
              "submitter": "Species xxx submitter"
            },
            "files": ["Spx_1.fastq", "Spx_2.fastq"],
            "sample_name": "sample1"
          }
          ]
      }
      ],

    "samples": 
      [
      {
        "sample_name": "sample1",
        "info": {
          "title": "Species xxx RNAseq sample 1",
          "description": "Species xxx RNAseq sample 1 description text"
        }
      }
      ]
  }
  
  * Remember to link the runs and samples with the same sample_name (this field is only used as a link)
  * There can be several experiments, runs and sample, but they all belong to 1 study
  * The info to be inserted in every table are in the "info" data
  * Samples need the "production_name" to link correctly to the right species
  * Runs can have 1 or 2 files, to be used by the RNA-seq alignment pipeline
  
=back

=head1 CONFIGURATION AND ENVIRONMENT

RNAseqDB::DB requires no configuration files or environment variables.


=head1 DEPENDENCIES

 * Bio::EnsEMBL::ENA (eg-ena)
 * Log::Log4perl
 * DBIx::Class


=head1 BUGS AND LIMITATIONS

...

=head1 AUTHOR

Matthieu Barba  C<< <mbarba@ebi.ac.uk> >>

