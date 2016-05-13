use utf8;
package RNAseqDB::Schema::Result::Track;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

RNAseqDB::Schema::Result::Track

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<track>

=cut

__PACKAGE__->table("track");

=head1 ACCESSORS

=head2 track_id

  data_type: 'integer'
  extra: {unsigned => 1}
  is_auto_increment: 1
  is_nullable: 0

=head2 title

  data_type: 'text'
  is_nullable: 1

=head2 description

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
  extra: {list => ["ACTIVE","RETIRED","MERGED"]}
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "track_id",
  {
    data_type => "integer",
    extra => { unsigned => 1 },
    is_auto_increment => 1,
    is_nullable => 0,
  },
  "title",
  { data_type => "text", is_nullable => 1 },
  "description",
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
    extra => { list => ["ACTIVE", "RETIRED", "MERGED"] },
    is_nullable => 1,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</track_id>

=back

=cut

__PACKAGE__->set_primary_key("track_id");

=head1 RELATIONS

=head2 analyses

Type: has_many

Related object: L<RNAseqDB::Schema::Result::Analysis>

=cut

__PACKAGE__->has_many(
  "analyses",
  "RNAseqDB::Schema::Result::Analysis",
  { "foreign.track_id" => "self.track_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 drupal_node_tracks

Type: has_many

Related object: L<RNAseqDB::Schema::Result::DrupalNodeTrack>

=cut

__PACKAGE__->has_many(
  "drupal_node_tracks",
  "RNAseqDB::Schema::Result::DrupalNodeTrack",
  { "foreign.track_id" => "self.track_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 files

Type: has_many

Related object: L<RNAseqDB::Schema::Result::File>

=cut

__PACKAGE__->has_many(
  "files",
  "RNAseqDB::Schema::Result::File",
  { "foreign.track_id" => "self.track_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 sra_tracks

Type: has_many

Related object: L<RNAseqDB::Schema::Result::SraTrack>

=cut

__PACKAGE__->has_many(
  "sra_tracks",
  "RNAseqDB::Schema::Result::SraTrack",
  { "foreign.track_id" => "self.track_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2016-05-13 14:43:34
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Ofgjv1SywzQL6RvUe7wuDA


# You can replace this text with custom code or comments, and it will be preserved on regeneration

1;

