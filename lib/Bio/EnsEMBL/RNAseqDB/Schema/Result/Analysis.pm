use utf8;
package Bio::EnsEMBL::RNAseqDB::Schema::Result::Analysis;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::EnsEMBL::RNAseqDB::Schema::Result::Analysis

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<analysis>

=cut

__PACKAGE__->table("analysis");

=head1 ACCESSORS

=head2 analysis_id

  data_type: 'integer'
  extra: {unsigned => 1}
  is_auto_increment: 1
  is_nullable: 0

=head2 analysis_description_id

  data_type: 'integer'
  extra: {unsigned => 1}
  is_foreign_key: 1
  is_nullable: 1

=head2 track_analysis_id

  data_type: 'integer'
  extra: {unsigned => 1}
  is_foreign_key: 1
  is_nullable: 0

=head2 version

  data_type: 'text'
  is_nullable: 1

=head2 command

  data_type: 'text'
  is_nullable: 1

=head2 metasum

  data_type: 'char'
  is_nullable: 1
  size: 32

=head2 date

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: current_timestamp
  is_nullable: 1

=head2 status

  data_type: 'enum'
  default_value: 'ACTIVE'
  extra: {list => ["ACTIVE","RETIRED"]}
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "analysis_id",
  {
    data_type => "integer",
    extra => { unsigned => 1 },
    is_auto_increment => 1,
    is_nullable => 0,
  },
  "analysis_description_id",
  {
    data_type => "integer",
    extra => { unsigned => 1 },
    is_foreign_key => 1,
    is_nullable => 1,
  },
  "track_analysis_id",
  {
    data_type => "integer",
    extra => { unsigned => 1 },
    is_foreign_key => 1,
    is_nullable => 0,
  },
  "version",
  { data_type => "text", is_nullable => 1 },
  "command",
  { data_type => "text", is_nullable => 1 },
  "metasum",
  { data_type => "char", is_nullable => 1, size => 32 },
  "date",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => \"current_timestamp",
    is_nullable => 1,
  },
  "status",
  {
    data_type => "enum",
    default_value => "ACTIVE",
    extra => { list => ["ACTIVE", "RETIRED"] },
    is_nullable => 1,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</analysis_id>

=back

=cut

__PACKAGE__->set_primary_key("analysis_id");

=head1 RELATIONS

=head2 analysis_description

Type: belongs_to

Related object: L<Bio::EnsEMBL::RNAseqDB::Schema::Result::AnalysisDescription>

=cut

__PACKAGE__->belongs_to(
  "analysis_description",
  "Bio::EnsEMBL::RNAseqDB::Schema::Result::AnalysisDescription",
  { analysis_description_id => "analysis_description_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "CASCADE",
  },
);

=head2 track_analysis

Type: belongs_to

Related object: L<Bio::EnsEMBL::RNAseqDB::Schema::Result::TrackAnalysis>

=cut

__PACKAGE__->belongs_to(
  "track_analysis",
  "Bio::EnsEMBL::RNAseqDB::Schema::Result::TrackAnalysis",
  { track_analysis_id => "track_analysis_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07047 @ 2017-12-05 09:59:58
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:ligRqDPN3WgBrr0tVzMVIQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
