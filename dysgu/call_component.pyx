#cython: language_level=3, boundscheck=False, c_string_type=unicode, c_string_encoding=utf8, infer_types=True

from __future__ import absolute_import
from collections import Counter, defaultdict
import click
import numpy as np
import itertools
from dysgu import io_funcs, assembler, coverage
from dysgu.map_set_utils cimport hash as xxhasher
from dysgu.map_set_utils cimport is_overlapping, cigar_clip
import warnings
from pysam.libcalignedsegment cimport AlignedSegment
from libc.stdint cimport uint64_t
from pysam.libchtslib cimport bam_get_qname

warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.simplefilter(action='ignore', category=FutureWarning)


def echo(*args):
    click.echo(args, err=True)


cdef class AlignmentItem:
    """Data holder for classifying alignments into SV types"""
    cdef public int chrA, chrB, priA, priB, rA, rB, posA, endA, posB, endB, strandA, strandB, left_clipA, right_clipA,\
        left_clipB, right_clipB, breakA_precise, breakB_precise, breakA, breakB, a_qstart, a_qend, b_qstart, b_qend,\
        query_gap, read_overlaps_mate
    cdef public str svtype, join_type
    def __cinit__(self, int chrA, int chrB, int priA, int priB, int rA, int rB, int posA, int endA, int posB, int endB,
                  int strandA, int strandB, int left_clipA, int right_clipA, int left_clipB, int right_clipB,
                  int a_qstart, int a_qend, int b_qstart, int b_qend, int read_overlaps_mate):
        self.chrA = chrA
        self.chrB = chrB
        self.priA = priA
        self.priB = priB
        self.rA = rA
        self.rB = rB
        self.posA = posA
        self.endA = endA
        self.posB = posB
        self.endB = endB
        self.strandA = strandA
        self.strandB = strandB
        self.left_clipA = left_clipA
        self.right_clipA = right_clipA
        self.left_clipB = left_clipB
        self.right_clipB = right_clipB
        self.a_qstart = a_qstart
        self.a_qend = a_qend
        self.b_qstart = b_qstart
        self.b_qend = b_qend
        self.read_overlaps_mate = read_overlaps_mate

        # These will be determined
        self.breakA_precise = 0
        self.breakB_precise = 0
        self.breakA = -1
        self.breakB = -1
        self.svtype = ""
        self.join_type = ""
        self.query_gap = -1  # used to infer insertions in split reads


cdef n_aligned_bases(ct):
    cdef int opp, l, aligned, large_gaps, n_small_gaps
    aligned, large_gaps, n_small_gaps = 0, 0, 0
    for opp, l in ct:
        if opp == 0:
            aligned += l
        elif opp == 1 or opp == 2:
            if l >= 30:
                large_gaps += l
            else:
                n_small_gaps += 1

    return float(aligned), float(large_gaps), float(n_small_gaps)


cdef dict extended_attrs(reads1, reads2, spanning, min_support, svtype):
    r = {"pe": 0, "supp": 0, "sc": 0, "DP": [], "DApri": [], "DN": [], "NMpri": [], "NP": 0, "DAsupp": [], "NMsupp": [],
         "maxASsupp": [], "MAPQpri": [], "MAPQsupp": [], "plus": 0, "minus": 0, "spanning": len(spanning), "NMbase": [],
         "n_sa": []}
    paired_end = set([])
    seen = set([])

    cdef bint is_insertion = svtype == "INS"
    cdef int flag, pe_support
    cdef float a_bases, large_gaps, n_small_gaps
    # cdef list reads
    # for reads in (reads1, reads2):
    for a in itertools.chain(reads1, reads2):

        qname = a.qname
        if qname not in seen:  # Add these once for each pair, its common across all alignments of template
            if a.has_tag("DP"):
                r["DP"].append(float(a.get_tag("DP")))
            if a.has_tag("DN"):
                r["DN"].append(float(a.get_tag("DN")))
            seen.add(qname)

        pe_support = 0
        flag = a.flag
        if flag & 2:
            r["NP"] += 1

        has_sa = a.has_tag("SA")
        if has_sa:
            r["n_sa"].append(a.get_tag("SA").count(";"))

        a_bases, large_gaps, n_small_gaps = n_aligned_bases(a.cigartuples)
        r["n_gaps"].append(n_small_gaps / a_bases)

        if not flag & 256:  # Primary reads
            r["MAPQpri"].append(a.mapq)
            if qname in paired_end:  # If two primary reads from same pair
                r["pe"] += 1
                pe_support = 1
            else:
                paired_end.add(qname)

            # Special case. Insertion inferred to occur between two primary alignments
            if not pe_support and is_insertion:
                if (has_sa and flag & 2) or flag & 8:  # normal pair, or mate unmapped
                    r["pe"] += 1

            if a.has_tag("DA"):
                r["DApri"].append(float(a.get_tag("DA")))
            if a.has_tag("NM"):
                if a_bases:
                    nm = float(a.get_tag("NM"))
                    r["NMpri"].append(nm / a_bases)
                    r["NMbase"].append((nm - large_gaps) / a_bases)
                else:
                    r["NMpri"].append(0)

        elif flag & 2304:  # Supplementary (and not primary if -M if flagged using bwa)
            r["supp"] += 1
            r["MAPQsupp"].append(a.mapq)
            if a.has_tag("DA"):
                r["DAsupp"].append(float(a.get_tag("DA")))
            if a.has_tag("NM"):
                if a_bases:
                    r["NMsupp"].append(float(a.get_tag("NM")) / a_bases)
                else:
                    r["NMsupp"].append(0)
            if a.has_tag("AS"):
                r["maxASsupp"].append(float(a.get_tag("AS")))

        if flag & 16:
            r["minus"] += 1
        else:
            r["plus"] += 1

        ct = a.cigartuples
        if ct[0][0] == 4 or ct[-1][0] == 4:
            r["sc"] += 1

    for a in spanning:

        qname = a.qname
        if qname not in seen:  # Add these once for each pair, its common across all alignments of template
            if a.has_tag("DP"):
                r["DP"].append(float(a.get_tag("DP")))
            if a.has_tag("DN"):
                r["DN"].append(float(a.get_tag("DN")))
            seen.add(qname)

        flag = a.flag
        if flag & 2:
            r["NP"] += 1

        if a.has_tag("SA"):
            r["n_sa"].append(a.get_tag("SA").count(";"))

        a_bases, large_gaps, n_small_gaps = n_aligned_bases(a.cigartuples)
        r["n_gaps"].append(n_small_gaps / a_bases)

        if flag & 2304:  # Supplementary
            r["supp"] += 2
            r["MAPQsupp"].append(a.mapq)
            if a.has_tag("DA"):
                r["DAsupp"].append(float(a.get_tag("DA")))
            if a.has_tag("NM"):
                if a_bases:
                    r["NMsupp"].append(float(a.get_tag("NM")) / a_bases)
                else:
                    r["NMsupp"].append(0)
            if a.has_tag("AS"):
                r["maxASsupp"].append(float(a.get_tag("AS")))

        else:  # Primary reads
            r["MAPQpri"].append(a.mapq)
            if qname in paired_end:  # If two primary reads from same pair
                r["pe"] += 2
            else:
                paired_end.add(qname)
            if a.has_tag("DA"):
                r["DApri"].append(float(a.get_tag("DA")))
            if a.has_tag("NM"):
                if a_bases:
                    nm = float(a.get_tag("NM"))
                    r["NMpri"].append(nm / a_bases)
                    r["NMbase"].append((nm - large_gaps) / a_bases)
                else:
                    r["NMpri"].append(0)

        if flag & 16:
            r["minus"] += 1
        else:
            r["plus"] += 1

    if r["pe"] + r["supp"] < min_support:
        return {}

    cdef str k
    for k in ("NMpri", "NMsupp", "NMbase", "n_gaps"):
        if len(r[k]) > 0:
            r[k] = np.mean(r[k]) * 100
        else:
            r[k] = 0
    for k in ("DP", "DApri", "DN", "DAsupp", "MAPQpri", "MAPQsupp", "n_sa"):
        if len(r[k]) > 0:
            r[k] = np.mean(r[k])
        else:
            r[k] = 0

    if len(r["maxASsupp"]) > 0:
        r["maxASsupp"] = int(max(r["maxASsupp"]))
    else:
        r["maxASsupp"] = 0

    return r


cdef dict normal_attrs(reads1, reads2, spanning, min_support, svtype):

    r = {"pe": 0, "supp": 0, "sc": 0, "NMpri": [], "NMsupp": [],
         "maxASsupp": [], "MAPQpri": [], "MAPQsupp": [], "plus": 0, "minus": 0, "NP": 0,
         "spanning": len(spanning), "NMbase": [], "n_gaps": [], "n_sa": []}

    paired_end = set([])
    seen = set([])
    cdef bint is_insertion = svtype == "INS"
    cdef int flag, pe_support
    cdef float a_bases, large_gaps, n_small_gaps

    for a in itertools.chain(reads1, reads2):
        qname = a.qname
        flag = a.flag
        has_sa = a.has_tag("SA")
        pe_support = 0

        if has_sa:
            r["n_sa"].append(a.get_tag("SA").count(";"))

        a_bases, large_gaps, n_small_gaps = n_aligned_bases(a.cigartuples)
        r["n_gaps"].append(n_small_gaps / a_bases)

        if flag & 2:
            r["NP"] += 1

        if flag & 2304:  # Supplementary
            r["supp"] += 1
            r["MAPQsupp"].append(a.mapq)
            if a.has_tag("NM"):
                if a_bases:
                    r["NMsupp"].append(float(a.get_tag("NM")) / a_bases)
                else:
                    r["NMsupp"].append(0)
            if a.has_tag("AS"):
                r["maxASsupp"].append(float(a.get_tag("AS")))

        else:  # primary
            r["MAPQpri"].append(a.mapq)
            if qname in paired_end:  # If two primary reads from same pair
                # echo(qname, a.flag, a.pos)
                r["pe"] += 1
                pe_support = 1
            else:
                paired_end.add(qname)

            # Special case. Insertion inferred to occur between two primary alignments
            if not pe_support and is_insertion:
                if (has_sa and flag & 2) or flag & 8:  # normal pair, or mate unmapped
                    r["pe"] += 1

            if a.has_tag("NM"):
                if a_bases:
                    nm = float(a.get_tag("NM"))
                    r["NMpri"].append(nm / a_bases)
                    r["NMbase"].append((nm - large_gaps) / a_bases)
                else:
                    r["NMpri"].append(0)

        if flag & 16:
            r["minus"] += 1
        else:
            r["plus"] += 1

        ct = a.cigartuples
        if ct[0][0] == 4 or ct[-1][0] == 4:
            r["sc"] += 1

    for a in spanning:  # Same but dont count softclip
        qname = a.qname
        flag = a.flag
        a_bases, large_gaps, n_small_gaps = n_aligned_bases(a.cigartuples)

        if a.has_tag("SA"):
            r["n_sa"].append(a.get_tag("SA").count(";"))

        r["n_gaps"].append(n_small_gaps / a_bases)
        if flag & 2:
            r["NP"] += 1

        if not flag & 256:  # Primary reads
            r["MAPQpri"].append(a.mapq)
            if qname in paired_end:  # If two primary reads from same pair
                r["pe"] += 2
            else:
                paired_end.add(qname)
            if a.has_tag("NM"):
                if a_bases:
                    nm = float(a.get_tag("NM"))
                    r["NMpri"].append(nm / a_bases)
                    r["NMbase"].append((nm - large_gaps) / a_bases)
                else:
                    r["NMpri"].append(0)

        elif flag & 2304:  # Supplementary
            r["supp"] += 2
            r["MAPQsupp"].append(a.mapq)
            if a.has_tag("NM"):
                if a_bases:
                    r["NMsupp"].append(float(a.get_tag("NM")) / a_bases)
                else:
                    r["NMsupp"].append(0)
            if a.has_tag("AS"):
                r["maxASsupp"].append(float(a.get_tag("AS")))

        if flag & 16:
            r["minus"] += 1
        else:
            r["plus"] += 1

    cdef str k
    for k in ("NMpri", "NMsupp", "NMbase", "n_gaps"):
        if len(r[k]) > 0:
            r[k] = np.mean(r[k]) * 100
        else:
            r[k] = 0
    for k in ("MAPQpri", "MAPQsupp", "n_sa"):
        if len(r[k]) > 0:
            r[k] = np.mean(r[k])
        else:
            r[k] = 0
    if len(r["maxASsupp"]) > 0:
        r["maxASsupp"] = int(max(r["maxASsupp"]))
    else:
        r["maxASsupp"] = 0

    return r


cdef dict count_attributes(reads1, reads2, spanning, int min_support, int extended_tags, svtype):

    if extended_tags:
        return extended_attrs(reads1, reads2, spanning, min_support, svtype)

    else:
        return normal_attrs(reads1, reads2, spanning, min_support, svtype)


cdef int within_read_end_position(event_pos, svtype, cigartuples, cigar_index):
    # If a deletion has a poorly aligned section at the end of pos2, merge nearby events until target matches
    cdef int i, end, idx, opp, length, cigar_skip, n_aligned_bases, target_bases
    if svtype == 1:  # insertion (or other e.g. duplication/inversion within read)
        return event_pos + 1
    else:  # deletion type
        end = event_pos + cigartuples[cigar_index][1]
        return end

    #     original_end = end
    #     cigar_skip = 0
    #     idx = cigar_index + 1
    #     n_aligned_bases = 0
    #     target_bases = target_bases = min(150, max(100, int((end - event_pos) / 2)))
    #
    #     for idx in range(cigar_index + 1, len(cigartuples)):
    #     #while idx < len(cigartuples):
    #
    #         opp, length = cigartuples[idx]
    #         # echo(opp, length, n_aligned_bases, target_bases)
    #         if opp == 1:  # insertion
    #             if length >= 30:
    #                 break
    #             # idx += 1
    #
    #         elif opp == 2:
    #             if length >= 30:
    #                 target_bases = min(150, max(100, int(length / 2)))
    #                 n_aligned_bases = 0
    #                 cigar_skip = 1
    #             # idx += 1
    #             end += length
    #
    #         elif opp == 0:
    #             n_aligned_bases += length
    #             if n_aligned_bases > target_bases:
    #                 break
    #             end += length
    #             # idx += 1
    # if cigar_skip == 1:
    #     return end
    # else:
    #     return original_end  # use original cigar end point


cdef tuple guess_informative_pair(aligns):

    if len(aligns) == 2:
        a_cigar_info, a = aligns[0]
        b_cigar_info, b = aligns[1]
        # Make sure aligns map different break points
        # echo(a_cigar_info, 0 < a_cigar_info[5] < len(a.cigartuples) - 1, b_cigar_info, 0 < b_cigar_info[5] < len(b.cigartuples) - 1)
        if 0 < a_cigar_info[5] < len(a.cigartuples) - 1:
            cigar_index = a_cigar_info[5]
            event_pos = a_cigar_info[6]
            ci = a.cigartuples[cigar_index]
            # echo("1")
            return (ci[0],
                    a.rname,
                    event_pos,
                    event_pos + 1 if ci[0] == 1 else event_pos + a.cigartuples[cigar_index][1] + 1,
                    a.cigartuples[cigar_index][1],
                    a)

        elif 0 < b_cigar_info[5] < len(b.cigartuples) - 1:
            cigar_index = b_cigar_info[5]
            event_pos = b_cigar_info[6]
            ci = b.cigartuples[cigar_index]
            # echo("2")
            return (ci[0],
                    b.rname,
                    event_pos,
                    event_pos + 1 if ci[0] == 1 else event_pos + b.cigartuples[cigar_index][1] + 1,
                    b.cigartuples[cigar_index][1],
                    b)
        # echo(a.pos, b.pos)
        # echo(a_cigar_info, b_cigar_info)
        a_pos = a_cigar_info[6]  # Position may have been inferred from SA tag, use this if available
        b_pos = b_cigar_info[6]
        # if abs(a.pos - b.pos) < 25 or abs(a.reference_end - b.reference_end) < 25:
        # if abs(b_pos - a_pos) < 25:  # Todo add param
            # echo("3")
            # echo(abs(a.pos - b.pos) < 25, abs(a.reference_end - b.reference_end) < 25)
            # return
        # if a.pos < b.pos:  # a and b will be same on same chrom
        if a_pos < b_pos:
            # echo("4")
            return a, b
        # echo("5")
        return b, a

    pri_first = None
    sup_first = None
    pri_second = None
    sup_second = None
    for node_info, i in aligns:

        if not i.flag & 2304:  # (Not pri, supplementary) --> is primary
            if i.flag & 64:
                pri_first = i
            else:
                pri_second = i
        else: #elif i.flag & 2048:  # Supplementary, -M flag of bwa marks supplementary as not primary
            if i.flag & 64:
                sup_first = i
            else:
                sup_second = i
    a = None
    b = None
    if pri_first and sup_first:
        a = pri_first
        b = sup_first
    elif pri_second and sup_second:
        a = pri_second
        b = sup_second
    elif pri_first and pri_second:
        a = pri_first
        b = pri_second
    if a is None:
        # echo("4")
        return None
    if a.pos < b.pos:
        return a, b
    return b, a


cdef int same_read_overlaps_mate(a_chrom, b_chrom, a_start, a_end, b_start, b_end, a, b):
    aflag = a.flag
    bflag = b.flag
    # echo(aflag, bflag, is_overlapping(a_start, a_end, a.pnext, a.pnext + 150), is_overlapping(b_start, b_end, a.pnext, b.pnext + 150))
    # If data is paired-end, check if one supplementary overlaps the other primary read
    if aflag & 1 and not aflag & 8 and a_chrom == b_chrom and aflag & 64 == bflag & 64:  # same read, one is supplementary

        if is_overlapping(b_start, b_end, a_start, a_end):
            return 1

        # if bflag & 2304 and not aflag & 2304:  # b is supplementary
        #     if b.rnext == a_chrom and is_overlapping(b_start, b_end, b.pnext, b.pnext + 150):
        #         return 1
        #
        # elif aflag & 2304 and not bflag & 2304:  # a is supplementary
        #     if a.rnext == b_chrom and is_overlapping(a_start, a_end, a.pnext, b.pnext + 150):
        #         return 1

        # if bflag & 2304 and not aflag & 2304:  # b is supplementary
        #     if b.rnext == a_chrom and is_overlapping(a_start, a_end, a.pnext, a.pnext + 150):
        #         return 1
        #     if a.rnext == b_chrom and is_overlapping(b_start, b_end, a.pnext, b.pnext + 150):
        #         return 1
        #
        # elif aflag & 2304 and not bflag & 2304:  # a is supplementary
        #
        #     if b.rnext == a_chrom and is_overlapping(a_start, a_end, b.pnext, b.pnext + 150):
        #         return 1
        #     if a.rnext == b_chrom and is_overlapping(b_start, b_end, a.pnext, b.pnext + 150):
        #         return 1
    return 0


cdef make_sv_alignment_item(a, b):

    a_ct = a.cigartuples
    b_ct = b.cigartuples

    a_qstart, a_qend, b_qstart, b_qend = start_end_query_pair(a, b)

    # Soft-clips for the chosen pair, plus template start of alignment
    left_clip_a, right_clip_a, left_clip_b, right_clip_b = mask_soft_clips(a.flag, b.flag, a_ct, b_ct)

    a_chrom, b_chrom = a.rname, b.rname
    a_start, a_end = a.pos, a.reference_end
    b_start, b_end = b.pos, b.reference_end
    read_overlaps_mate = same_read_overlaps_mate(a_chrom, b_chrom, a_start, a_end, b_start, b_end, a, b)

    v_item = AlignmentItem(a_chrom, b_chrom,
                           int(not a.flag & 2304),  # is primary
                           int(not b.flag & 2304),
                           1 if a.flag & 64 else 2,
                           1 if b.flag & 64 else 2,
                           a_start, a_end,
                           b_start, b_end,
                           3 if a.flag & 16 == 0 else 5,
                           3 if b.flag & 16 == 0 else 5,
                           left_clip_a, right_clip_a,
                           left_clip_b, right_clip_b,
                           a_qstart, a_qend, b_qstart, b_qend,
                           read_overlaps_mate
                           )

    if v_item.left_clipA and v_item.right_clipA:
        if a_ct[0][1] >= a_ct[-1][1]:
            v_item.right_clipA = 0
        else:
            v_item.left_clipA = 0

    if v_item.left_clipB and v_item.right_clipB:
        if b_ct[0][1] >= b_ct[-1][1]:
            v_item.right_clipB = 0
        else:
            v_item.left_clipB = 0

    return v_item


cdef dict single(infile, rds, int insert_size, int insert_stdev, int clip_length, int min_support,
                 int to_assemble, int extended_tags):
    # Infer the other breakpoint from a single group
    # Make sure at least one read is worth calling
    cdef int min_distance = insert_size + (2*insert_stdev)
    cdef int n_templates = len(set([i.qname for _, i in rds]))

    if n_templates == 1:
        # Filter for paired ends, will also remove single end reads though
        if not any(not i.flag & 2 or i.rname != i.rnext or node_info[5] != 2 or
                   (i.flag & 1 and abs(i.tlen) > min_distance)
                   for node_info, i in rds):
            return {}

    # Groupby template name to check for split reads
    precise_a = []
    precise_b = []
    informative = []  # make call from these
    informative_reads = []  # count attributes from these
    u_reads = []
    v_reads = []
    spanning_alignments = []  # make call from these if available (and count attributes)

    generic_insertions = []

    tmp = defaultdict(list)  # group by template name
    for cigar_info, align in rds:
        tmp[align.qname].append((cigar_info, align))

    cdef AlignmentItem v_item, itm
    cdef int left_clip_a, right_clip_a, left_clip_b, right_clip_b

    for temp_name, alignments in tmp.items():
        l_align = list(alignments)
        # echo(temp_name, len(l_align))
        if len(l_align) > 1:
            pair = guess_informative_pair(l_align)
            # echo("pair", pair)
            if pair is not None:
                if len(pair) == 2:
                    a, b = pair

                    u_reads.append(a)
                    v_reads.append(b)
                    v_item = make_sv_alignment_item(a, b)
                    classify_d(v_item)
                    # if a.qname == "D00360:19:H8VDAADXX:2:2213:10408:33721":
                    # echo(a.qname, a.pos, b.pos, v_item.svtype)
                    if v_item.breakA_precise:
                        precise_a.append(v_item.breakA)
                    if v_item.breakB_precise:
                        precise_b.append(v_item.breakB)
                    informative.append(v_item)
                    informative_reads += [item[1] for item in l_align]

                else:
                    spanning_alignments.append(pair)
                    u_reads.append(pair[5])

        else:  # Single alignment, check spanning
            cigar_info, a = alignments[0]
            cigar_index = cigar_info[5]

            if 0 < cigar_index < len(a.cigartuples) - 1:  # Alignment spans SV
                event_pos = cigar_info[6]
                ci = a.cigartuples[cigar_index]
                spanning_alignments.append((ci[0],
                                            a.rname,
                                            event_pos,
                                            within_read_end_position(event_pos, ci[0], a.cigartuples, cigar_index),
                                            # event_pos + 1 if ci[0] == 1 else event_pos + a.cigartuples[cigar_index][1] + 1,
                                            a.cigartuples[cigar_index][1],
                                            a))
                u_reads.append(a)

            else:  # generic insertion
                generic_insertions.append(a)

    # echo(len(informative_reads), "generic", len(generic_insertions))
    if len(informative_reads) + (2*len(spanning_alignments)) < min_support:

        for aln in generic_insertions:
            if not aln.flag & 2304:  # skip supplementary
                v_item = make_sv_alignment_item(aln, aln)

                if v_item.left_clipA:
                    v_item.breakA = aln.pos
                    v_item.breakB = aln.pos
                    v_item.breakA_precise = 1
                    v_item.breakB_precise = 1
                    v_item.join_type = "5to3"
                    # echo("left y", aln.pos)

                elif v_item.right_clipA:
                    v_item.breakA = aln.reference_end
                    v_item.breakB = aln.reference_end
                    v_item.breakA_precise = 1
                    v_item.breakB_precise = 1
                    v_item.join_type = "3to5"
                    # echo("right y", aln.reference_end)
                else:
                    if aln.flag & 1 and aln.flag & 2: # bool(aln.flag & 16) != bool(aln.flag & 32):  # paired and opposing strand
                        if aln.flag & 16:  # guess left
                            v_item.breakA = aln.pos
                            v_item.breakB = aln.pos
                            v_item.join_type = "5to3"
                            # echo("left", aln.pos)
                        else:
                            v_item.breakA = aln.reference_end
                            v_item.breakB = aln.reference_end
                            v_item.join_type = "3to5"
                            # echo("right", aln.reference_end)
                    else:
                        continue

                v_item.svtype = "INS"
                # echo(v_item.breakA, v_item.breakB, v_item.breakA_precise)

                if v_item.left_clipA:
                    u_reads.append(aln)
                elif v_item.right_clipA:
                    v_reads.append(aln)

                if v_item.breakA_precise:
                    precise_a.append(v_item.breakA)
                elif v_item.breakB_precise:
                    precise_b.append(v_item.breakB)

                informative.append(v_item)

    # echo("--->", len(informative), len(spanning_alignments), len(u_reads), len(v_reads))
    if len(informative) == 0 and len(spanning_alignments) == 0:
        return {}

    info = {}
    cdef int min_found_support = 0
    cdef str svtype, jointype
    if len(spanning_alignments) > 0:

        # make call from spanning alignments if possible
        svtype_m = Counter([i[0] for i in spanning_alignments]).most_common()[0][0]
        spanning_alignments = [i for i in spanning_alignments if i[0] == svtype_m]

        posA_arr = [i[2] for i in spanning_alignments]
        posA = int(np.median(posA_arr))
        posA_95 = int(abs(int(np.percentile(posA_arr, [97.5])) - posA))
        posB_arr = [i[3] for i in spanning_alignments]
        posB = int(np.median(posB_arr))
        posB_95 = int(abs(int(np.percentile(posB_arr, [97.5])) - posB))
        chrom = spanning_alignments[0][1]
        svlen = int(np.mean([i[4] for i in spanning_alignments]))
        ab = abs(posB - posA)
        info.update({"svtype": "DEL" if svtype_m == 2 else "INS",
                     "join_type": "3to5",
                     "chrA": chrom, "chrB": chrom, "posA": posA, "posB": posB, "cipos95A": posA_95, "cipos95B": posB_95,
                     "preciseA": True, "preciseB": True, "svlen": svlen if svlen >= ab else ab,
                     })
        u_reads = [i[5] for i in spanning_alignments]
        v_reads = []
        min_found_support = len(spanning_alignments)

    else:
        call_informative = Counter([(itm.svtype, itm.join_type) for itm in informative]).most_common()
        svtype, jointype = call_informative[0][0]
        info.update(make_call(informative, precise_a, precise_b, svtype, jointype, insert_size, insert_stdev))

        if len(info) < 2:
            return {}

        min_found_support = call_informative[0][1]

    attrs = count_attributes(informative_reads, [], [i[5] for i in spanning_alignments], min_support, extended_tags,
                             info["svtype"])

    # hack to prevent count_attribute missing single reads that support an insertion
    if min_found_support > attrs["pe"] + attrs["supp"] + (2*attrs["spanning"]):
        attrs["pe"] = min_found_support

    # echo(call_informative)
    # quit()
    # echo(info)
    # echo(attrs)
    # Remove low support calls
    if not attrs:
        return {}
    if attrs["pe"] + attrs["supp"] + (2*attrs["spanning"]) < min_support:
        if info["svtype"] == "INS":
            if not (attrs["supp"] + attrs["spanning"] > 0 and attrs["supp"] + attrs["sc"] + attrs["spanning"] > min_support):
                return {}
        else:
            return {}

    info.update(attrs)

    as1 = None
    as2 = None

    if to_assemble or len(spanning_alignments) > 0:
        if info["preciseA"]:
            as1 = assembler.base_assemble(u_reads, info["posA"], 500)
        if info["preciseB"]:
            as2 = assembler.base_assemble(v_reads, info["posB"], 500)

    info["linked"] = 0
    info["block_edge"] = 0
    info["contig"] = None
    info["contig2"] = None
    rbases = 0
    if as1 is not None and "contig" in as1:
        if as1["left_clips"] or as1["right_clips"] or len(spanning_alignments) > 0:
            info["contig"] = as1["contig"]
            rbases += as1["ref_bases"]
    if as2 is not None and "contig" in as2:
        if as2["left_clips"] or as2["right_clips"]:
            info["contig2"] = as2["contig"]
            rbases += as2["ref_bases"]
    info["ref_bases"] = rbases

    return info


cdef tuple informative_pair(u, v):

    pri_u = None
    pri_v = None
    for i in u:
        ri_flag = i.flag & 64
        if not i.flag & 2304:  # Not pri, supplementary --> is primary
            pri_u = i
        for j in v:
            if j.flag & 64 == ri_flag:  # Same read
                # Same read, primary + supp, or supp + supp
                return i, j

            if not j.flag & 2304:  # Is primary
                pri_v = j

            # else Different read and sup, e.g. read 1 primary + read 2 supplementary (not informative)

    if pri_u is not None and pri_v is not None:
        return pri_u, pri_v


cdef void two_primary(AlignmentItem v):

    if v.posA < v.posB or (v.posA == v.posB and v.endA < v.endB):

        if v.strandA == 3 and v.strandB == 5:  # DEL type
            v.breakA = v.endA
            if v.right_clipA:
                v.breakA_precise = 1

            v.breakB = v.posB
            if v.left_clipB:
                v.breakB_precise = 1

            v.svtype = "DEL"
            v.join_type = "3to5"

        elif v.strandA == 5 and v.strandB == 3:  # DUP type
            v.breakA = v.posA
            if v.left_clipA:
                v.breakA_precise = 1

            v.breakB = v.endB
            if v.right_clipB:
                v.breakB_precise = 1

            v.svtype = "DUP"
            v.join_type = "5to3"

        else:  # INV type
            # Break to left or right
            if v.strandA == 5:

                if not (v.left_clipA or v.left_clipB) and (v.right_clipA or v.right_clipB):
                    v.breakA = v.endA
                    if v.right_clipA:
                        v.breakA_precise = 1

                    v.breakB = v.endB
                    if v.right_clipB:
                        v.breakB_precise = 1

                    v.svtype = "INV"
                    v.join_type = "3to3"

                else:
                    v.breakA = v.posA
                    if v.left_clipA:
                        v.breakA_precise = 1

                    v.breakB = v.posB
                    if v.right_clipB:
                        v.breakB_precise = 1

                    v.svtype = "INV"
                    v.join_type = "5to5"

            else:  # strand == 3
                if not (v.right_clipA or v.right_clipB) and (v.left_clipA or v.left_clipB):  # only left clips

                    if (v.posA < v.posB and v.left_clipB) or (v.posB < v.posA and v.left_clipA):  # guess right
                        v.breakA = v.endA
                        if v.right_clipA:
                            v.breakA_precise = 1

                        v.breakB = v.endB
                        if v.right_clipB:
                            v.breakB_precise = 1

                        v.svtype = "INV"
                        v.join_type = "3to3"

                    else:  # guess left
                        v.breakA = v.posA
                        if v.left_clipA:
                            v.breakA_precise = 1

                        v.breakB = v.posB
                        if v.left_clipB:
                            v.breakB_precise = 1

                        v.svtype = "INV"
                        v.join_type = "5to5"

                else:  # either no clips or right clips

                    v.breakA = v.endA
                    if v.left_clipA:
                        v.breakA_precise = 1

                    v.breakB = v.endB
                    if v.right_clipB:
                        v.breakB_precise = 1

                    v.svtype = "INV"
                    v.join_type = "3to3"

            # Break INV:DUP. Un-reachable
            # else:
            # # elif v.left_clipA and v.right_clipB:
            #     v.breakA = v.posA
            #     if v.left_clipA:
            #         v.breakA_precise = 1
            #
            #     v.breakB = v.endB
            #     if v.right_clipB:
            #         v.breakB_precise = 1
            #
            #     v.svtype = "INV:DUP"
            #     v.join_type = "3to5"

    else:  # B < A

        if v.strandA == 5 and v.strandB == 3:  # DEL type
            v.breakA = v.posA
            if v.left_clipA:
                v.breakA_precise = 1

            v.breakB = v.endB
            if v.right_clipB:
                v.breakB_precise = 1

            v.svtype = "DEL"
            v.join_type = "3to5"

        elif v.strandB == 5 and v.strandA == 3:  # DUP type
            v.breakA = v.endA
            if v.right_clipA:
                v.breakA_precise = 1

            v.breakB = v.posB
            if v.left_clipB:
                v.breakB_precise = 1

            v.svtype = "DUP"
            v.join_type = "5to3"

            # INV type
        elif v.strandA == 5:

            if not (v.left_clipA or v.left_clipB) and (v.right_clipA or v.right_clipB):
                v.breakA = v.endA
                if v.right_clipA:
                    v.breakA_precise = 1

                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1

                v.svtype = "INV"
                v.join_type = "3to3"

            else:
                v.breakA = v.posA
                if v.left_clipA:
                    v.breakA_precise = 1

                v.breakB = v.posB
                if v.right_clipB:
                    v.breakB_precise = 1

                v.svtype = "INV"
                v.join_type = "5to5"

        elif v.strandA == 3:

            if not (v.right_clipA or v.right_clipB) and (v.left_clipA or v.left_clipB):
                v.breakA = v.posA
                if v.right_clipA:
                    v.breakA_precise = 1

                v.breakB = v.posB
                if v.right_clipB:
                    v.breakB_precise = 1

                v.svtype = "INV"
                v.join_type = "5to5"

            else:

                v.breakA = v.endA
                if v.left_clipA:
                    v.breakA_precise = 1

                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1

                v.svtype = "INV"
                v.join_type = "3to3"


cdef void same_read(AlignmentItem v):

    cdef int query_gap, ref_gap

    if v.posA < v.posB or (v.posA == v.posB and v.endA <= v.endB):  # A is first

        if v.strandA == v.strandB:  # Same for 3 and 5 strand reads

            if is_overlapping(v.posA, v.endA, v.posB, v.endB):  # Nested DUP
                if v.left_clipA:
                    v.breakA = v.posA
                    v.breakA_precise = 1
                elif v.right_clipA:
                    v.breakA = v.endA
                    v.breakA_precise = 1
                else:
                    v.breakA = v.endA

                if v.left_clipB:
                    v.breakB = v.posB
                    v.breakB_precise = 1
                elif v.right_clipB:
                    v.breakB = v.endB
                    v.breakB_precise = 1
                else:
                    v.breakB = v.endB
                # Check if gap on query is bigger than gap on reference; call insertion if it is
                query_gap = v.b_qstart - v.a_qend  # as A is first
                ref_gap = v.breakB - v.breakA
                if ref_gap < query_gap:
                    v.svtype = "INS"
                    v.query_gap = query_gap
                else:
                    v.svtype = "DUP"
                v.join_type = "5to3"

            elif not v.left_clipA and not v.right_clipB:
                v.breakA = v.endA
                if v.right_clipA:
                    v.breakA_precise = 1
                v.breakB = v.posB
                if v.left_clipB:
                    v.breakB_precise = 1

                # Check if gap on query is bigger than gap on reference; call insertion if it is
                query_gap = v.b_qstart - v.a_qend  # as A is first
                ref_gap = v.breakB - v.breakA
                # echo(ref_gap, query_gap, v.breakA, v.breakB, v.read_overlaps_mate)
                if ref_gap < query_gap:
                    v.svtype = "INS"
                    v.join_type = "3to5"
                    v.query_gap = query_gap
                elif v.read_overlaps_mate:
                    v.svtype = "DUP"
                    v.join_type = "5to3"
                else:
                    v.svtype = "DEL"
                    v.join_type = "3to5"

            elif not v.right_clipA and not v.left_clipB:
                v.breakA = v.posA
                if v.left_clipA:
                    v.breakA_precise = 1
                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1
                v.svtype = "DUP"
                v.join_type = "5to3"

            elif not v.left_clipA and not v.left_clipB:
                v.breakA = v.endA
                if v.right_clipA:
                    v.breakA_precise = 1
                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1
                v.svtype = "INV"
                v.join_type = "3to3"

            else:
                v.breakA = v.posA
                if v.left_clipA:
                    v.breakA_precise = 1
                v.breakB = v.posB
                if v.left_clipB:
                    v.breakB_precise = 1
                v.svtype = "INV"
                v.join_type = "5to5"

        elif v.strandA == 5 and v.strandB == 3:

            # Break right
            if not v.left_clipA and not v.left_clipB:
                v.breakA = v.endA
                if v.right_clipA:
                    v.breakA_precise = 1

                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1

                v.svtype = "INV"
                v.join_type = "3to3"

            # Break left
            elif not v.right_clipA and not v.right_clipB:
                v.breakA = v.posA
                if v.left_clipA:
                    v.breakA_precise = 1

                v.breakB = v.posB
                if v.left_clipB:
                    v.breakB_precise = 1

                v.svtype = "INV"
                v.join_type = "5to5"

            elif is_overlapping(v.posA, v.endA, v.posB, v.endB):  # Inverted duplication
                v.breakA = v.posA
                if v.left_clipA:
                    v.breakA_precise = 1
                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1
                v.svtype = "INV:DUP"
                v.join_type = "5to3"

            elif v.right_clipA and v.left_clipB:
                v.breakA = v.endA
                v.breakB = v.posB
                v.svtype = "INV"
                v.join_type = "3to5"

            else:
            # elif v.left_clipA and v.right_clipB:
                v.breakA = v.posA
                v.breakB = v.endB
                v.svtype = "INV"
                v.join_type = "5to3"

        else:  # INV type
            # Break left
            if v.left_clipA and v.left_clipB:
                v.breakA_precise = 1
                v.breakB_precise = 1
                v.breakA = v.posA
                v.breakB = v.posB
                v.svtype = "INV"
                v.join_type = "5to5"
            # Break right
            elif v.right_clipA and v.right_clipB:
                v.breakA = v.endA
                v.breakB = v.endB
                v.breakA_precise = 1
                v.breakB_precise = 1
                v.svtype = "INV"
                v.join_type = "3to3"

            else:  # Guess using pos only
                v.breakA = v.posA
                v.breakB = v.posB
                v.svtype = "INV"
                if v.strandA == 5:
                    v.join_type = "5to5"
                else:
                    v.join_type = "3to3"

    # B is first
    else:
        if v.strandA == v.strandB:

            if is_overlapping(v.posA, v.endA, v.posB, v.endB):  # Nested DUP
                if v.left_clipA:
                    v.breakA = v.posA
                    v.breakA_precise = 1
                elif v.right_clipA:
                    v.breakA = v.endA
                    v.breakA_precise = 1
                else:
                    v.breakA = v.endA

                if v.left_clipB:
                    v.breakB = v.posB
                    v.breakB_precise = 1
                elif v.right_clipB:
                    v.breakB = v.endB
                    v.breakB_precise = 1
                else:
                    v.breakB = v.endB

                # Check if gap on query is bigger than gap on reference; call insertion if it is
                query_gap = v.b_qend - v.a_qstart  # as B is first
                ref_gap = v.breakB - v.breakA
                if ref_gap < query_gap:
                    v.svtype = "INS"
                    v.query_gap = query_gap
                else:
                    v.svtype = "DUP"

                v.join_type = "5to3"

            elif not v.left_clipB and not v.right_clipA:
                v.breakA = v.posA
                v.breakB = v.endB
                v.breakA_precise = 1
                v.breakB_precise = 1

                # Check if gap on query is bigger than gap on reference; call insertion if it is
                query_gap = v.b_qstart - v.a_qend  # as B is first
                ref_gap = v.breakA - v.breakB
                if ref_gap < query_gap:
                    v.svtype = "INS"
                    v.join_type = "3to5"
                    v.query_gap = query_gap
                elif v.read_overlaps_mate:
                    v.svtype = "DUP"
                    v.join_type = "5to3"
                else:
                    v.svtype = "DEL"
                    v.join_type = "3to5"

                # v.svtype = "DEL"
                # v.join_type = "3to5"

            elif not v.right_clipB and not v.left_clipA:
                v.breakA = v.endA
                v.breakB = v.posB
                v.breakA_precise = 1
                v.breakB_precise = 1
                v.svtype = "DUP"
                v.join_type = "5to3"

            else:
                v.breakA = v.posA
                v.breakB = v.posB
                v.svtype = "BND"
                v.join_type = f"{v.strandA}to{v.strandB}"

        else:  # INV type
            # Break left
            if v.left_clipA and v.left_clipB:
                v.breakA_precise = 1
                v.breakB_precise = 1
                v.breakA = v.posA
                v.breakB = v.posB
                v.svtype = "INV"
                v.join_type = "5to5"

            # Break right
            elif v.right_clipA and v.right_clipB:
                v.breakA_precise = 1
                v.breakB_precise = 1
                v.breakA = v.endA
                v.breakB = v.endB
                v.svtype = "INV"
                v.join_type = "3to3"

            else:  # Guess using pos only
                v.breakA = v.posA
                v.breakB = v.posB
                v.svtype = "INV"
                if v.strandA == 5:
                    v.join_type = "5to5"
                else:
                    v.join_type = "3to3"


cdef void different_read(AlignmentItem v):

    if v.posA < v.posB or (v.posA == v.posB and v.endA <= v.endB):  # A is first

        if v.strandA == 3 and v.strandB == 5:  # DEL type
            v.breakA = v.endA
            if v.right_clipA:
                v.breakA_precise = 1

            v.breakB = v.posB
            if v.left_clipB:
                v.breakB_precise = 1

            # v.svtype = "DEL"
            v.svtype = "INS"
            v.join_type = "3to5"

        elif v.strandA == 5 and v.strandB == 3:  # DUP type
            v.breakA = v.posA
            if v.left_clipA:
                v.breakA_precise = 1

            v.breakB = v.endB
            if v.right_clipB:
                v.breakB_precise = 1

            v.svtype = "DUP"
            v.join_type = "5to3"

        elif v.strandA == v.strandB:
            if is_overlapping(v.posA, v.endA, v.posB, v.endB):  # Nested

                if v.strandA == 3:  # Both forward strand
                    v.breakA = v.endA
                    if v.right_clipA:
                        v.breakA_precise = 1

                    v.breakB = v.endB
                    if v.right_clipB:
                        v.breakB_precise = 1
                    v.svtype = "INV"
                    v.join_type = "3to3"

                else:  # Both forward strand
                    v.breakA = v.posA
                    if v.left_clipA:
                        v.breakA_precise = 1

                    v.breakB = v.posB
                    if v.left_clipB:
                        v.breakB_precise = 1
                    v.svtype = "INV"
                    v.join_type = "5to5"

            elif not v.right_clipA and not v.right_clipB:
                v.breakA = v.posA
                if v.left_clipA:
                    v.breakA_precise = 1
                v.breakB = v.posB
                if v.left_clipB:
                    v.breakB_precise = 1
                v.svtype = "INV"
                v.join_type = "5to5"

            elif not v.left_clipA and not v.left_clipB:
                v.breakA = v.endA
                if v.right_clipA:
                    v.breakA_precise = 1
                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1
                v.svtype = "INV"
                v.join_type = "3to3"

            elif v.right_clipA and v.left_clipB:
                v.breakA = v.endA
                v.breakA_precise = 1
                v.breakB = v.posB
                v.breakB_precise = 1
                v.svtype = "INV:DUP"
                v.join_type = "5to3"

            else:
            # elif v.left_clipA and v.right_clipB:
                v.breakA = v.posA
                v.breakA_precise = 1
                v.breakB = v.endB
                v.breakB_precise = 1
                v.svtype = "INV:DUP"
                v.join_type = "3to5"

    else:  # B is first; B <= A

        if v.strandA == 5 and v.strandB == 3:  # DEL type
            v.breakA = v.posA
            if v.left_clipA:
                v.breakA_precise = 1

            v.breakB = v.endB
            if v.right_clipB:
                v.breakB_precise = 1

            # v.svtype = "DEL"
            v.svtype = "INS"
            v.join_type = "3to5"

        elif v.strandA == 3 and v.strandB == 5:  # DUP type
            v.breakA = v.endA
            if v.right_clipA:
                v.breakA_precise = 1

            v.breakB = v.posB
            if v.left_clipB:
                v.breakB_precise = 1

            v.svtype = "DUP"
            v.join_type = "5to3"

        elif v.strandA == v.strandB:  # INV type

            if is_overlapping(v.posA, v.endA, v.posB, v.endB):  # Nested DUP
                if v.left_clipA:
                    v.breakA = v.posA
                    v.breakA_precise = 1
                elif v.right_clipA:
                    v.breakA = v.endA
                    v.breakA_precise = 1
                else:
                    v.breakA = v.endA

                if v.left_clipB:
                    v.breakB = v.posB
                    v.breakB_precise = 1
                elif v.right_clipB:
                    v.breakB = v.endB
                    v.breakB_precise = 1
                else:
                    v.breakB = v.endB
                v.svtype = "DUP"
                v.join_type = "5to3"

            elif v.right_clipA and v.left_clipB:
                v.breakA = v.endA
                v.breakB = v.posB
                v.breakA_precise = 1
                v.breakB_precise = 1
                v.svtype = "DEL"
                v.join_type = "3to5"

            elif v.left_clipA and v.right_clipB:
                v.breakA = v.posA
                v.breakB = v.endB
                v.breakA_precise = 1
                v.breakB_precise = 1
                v.svtype = "DUP"
                v.join_type = "5to3"

            elif not v.left_clipB and not v.left_clipA:

                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1

                v.breakA = v.endA
                if v.right_clipA:
                    v.breakA_precise = 1
                v.svtype = "INV"
                v.join_type = "3to3"

            elif not v.right_clipB and not v.right_clipA:

                v.breakB = v.posB
                if v.left_clipB:
                    v.breakB_precise = 1

                v.breakA = v.posA
                if v.left_clipA:
                    v.breakA_precise = 1
                v.svtype = "INV"
                v.join_type = "5to5"

            elif v.strandA == 3:
                v.breakA = v.endA
                if v.right_clipA:
                    v.breakA_precise = 1
                v.breakB = v.endB
                if v.right_clipB:
                    v.breakB_precise = 1
                v.svtype = "INV"
                v.join_type = "3to3"

            else:
                v.breakA = v.posA
                if v.left_clipA:
                    v.breakA_precise = 1
                v.breakB = v.posB
                if v.left_clipB:
                    v.breakB_precise = 1
                v.svtype = "INV"
                v.join_type = "5to5"


cdef void translocation(AlignmentItem v):

    v.svtype = "TRA"

    if v.left_clipA:
        v.breakA = v.posA
        v.breakA_precise = 1
    elif v.right_clipA:
        v.breakA = v.endA
        v.breakA_precise = 1
    else:
        v.breakA = v.posA
        v.breakA_precise = 1

    if v.left_clipB:
        v.breakB = v.posB
        v.breakB_precise = 1
    elif v.right_clipB:
        v.breakB = v.endB
        v.breakB_precise = 1
    else:
        v.breakB = v.posB
        v.breakB_precise = 1
    v.join_type = f"{v.strandA}to{v.strandB}"


# cdef int is_overlapping(int x1, int x2, int y1, int y2) nogil:
#     return int(max(x1, y1) <= min(x2, y2))


cdef void classify_d(AlignmentItem v):

    v.breakA_precise = 0
    v.breakB_precise = 0

    if v.chrA != v.chrB:
        translocation(v)

    else:  # Intra-chromosomal
        # Find join type first, different for pri-sup, pri-pri
        if v.priA and v.priB:  # Both primary
            two_primary(v)
            # echo("two primary")
        else:  # One is a supplementary
            if v.rA == v.rB:
                same_read(v)
                # echo("same read")

            else:
                different_read(v)
                # echo("different read")


cdef tuple break_ops(positions, precise, int limit, float median_pos):

    ops = []
    cdef int i
    for i in positions:
        ops.append((i, 1, 0))
        ops.append((i + limit, -1, 0))
    cdef int v = 1
    if limit < 0:
        v = -1
    for i in precise:
        ops.append((i, 1, 1))
        if v == -1:
            ops.append((i + v + 1, -1, 1))
        else:
            ops.append((i + v, -1, 1))

    ops = sorted(ops, reverse=limit < 0)
    cdef int cum_sum = 0
    cdef int max_sum = 0
    cdef int max_sum_i = 0
    cdef int idx
    for idx, item in enumerate(ops):
        cum_sum += item[1]
        if cum_sum > max_sum:
            max_sum = cum_sum
            max_sum_i = idx

    cdef int break_point, cipos95, is_precise
    break_point, _, is_precise = ops[max_sum_i]
    cipos95 = 0
    if not is_precise:
        if any(i == break_point for i in precise):
            is_precise = 1
    # if not is_precise and not any(i == break_point for i in precise):
        # Calculate confidence interval around break

    if is_precise and len(precise) > 1:
        cipos95 = 0
    else:
        cipos95 = int(abs(int(np.percentile(positions, [97.5])) - median_pos))

    return break_point, cipos95, is_precise


cdef infer_unmapped_insertion_break_point(int main_A_break, int cipos95A, int preciseA, int main_B_break, int cipos95B,
                                          int preciseB):
    # A or B break pay be in accurate, try and infer svlen and a more accurate break point(s)
    cdef int svlen = 0
    cdef int mid
    # echo(main_A_break, main_B_break, preciseA, preciseB)
    if not preciseA and not preciseB:
        # Make break at mid point
        sep = abs(main_B_break - main_A_break)
        svlen = min(sep, max(cipos95A, cipos95B))
        mid = int(sep / 2) + min(main_A_break, main_B_break)
        main_A_break = mid
        main_B_break = mid + 1

    if not preciseA and preciseB:
        if main_A_break < main_B_break:
            main_A_break = main_B_break - 1
        else:
            main_A_break = main_B_break + 1
        svlen = int(cipos95A / 2)

    if not preciseB and preciseA:
        if main_A_break < main_B_break:
            main_B_break = main_A_break + 1
        else:
            main_B_break = main_A_break - 1
        svlen = int(cipos95B / 2)
    # echo(main_A_break, main_B_break, svlen)
    return main_A_break, cipos95A, preciseA, main_B_break, cipos95B, preciseB, svlen



cdef dict make_call(informative, breakA_precise, breakB_precise, svtype, jointype,
                    int insert_size, int insert_stdev):
    # Inspired by mosdepth algorithm +1 for start -1 for end using intervals where break site could occur
    # Use insert size to set a limit on where break site could occur
    cdef int limit = insert_size + insert_stdev

    # get bulk call
    positionsA = [i.breakA for i in informative]
    positionsB = [i.breakB for i in informative]
    cdef float median_A = np.median(positionsA)
    cdef float median_B = np.median(positionsB)
    cdef int main_A_break = 0
    cdef int main_B_break = 0
    cdef int cipos95A, cipos95B

    if svtype == "DEL":
        if median_A < median_B:
            main_A_break, cipos95A, preciseA = break_ops(positionsA, breakA_precise, limit, median_A)
            main_B_break, cipos95B, preciseB = break_ops(positionsB, breakB_precise, -limit, median_B)
        else:
            main_B_break, cipos95B, preciseA = break_ops(positionsB, breakB_precise, limit, median_B)
            main_A_break, cipos95A, preciseB = break_ops(positionsA, breakA_precise, -limit, median_A)

    elif svtype == "DUP":
        if median_A < median_B:
            main_A_break, cipos95A, preciseA = break_ops(positionsA, breakA_precise, -limit, median_A)
            main_B_break, cipos95B, preciseB = break_ops(positionsB, breakB_precise, limit, median_B)
        else:
            main_A_break, cipos95A, preciseA = break_ops(positionsA, breakA_precise, limit, median_A)
            main_B_break, cipos95B, preciseB = break_ops(positionsB, breakB_precise, -limit, median_B)

    # Generic types
    elif jointype == "3to3":
        main_A_break, cipos95A, preciseA = break_ops(positionsA, breakA_precise, limit, median_A)
        main_B_break, cipos95B, preciseB = break_ops(positionsB, breakB_precise, limit, median_B)

    elif jointype == "5to5":
        main_A_break, cipos95A, preciseA = break_ops(positionsA, breakA_precise, -limit, median_A)
        main_B_break, cipos95B, preciseB = break_ops(positionsB, breakB_precise, -limit, median_B)

    elif jointype == "3to5":
        main_A_break, cipos95A, preciseA = break_ops(positionsA, breakA_precise, limit, median_A)
        main_B_break, cipos95B, preciseB = break_ops(positionsB, breakB_precise, -limit, median_B)

    else:  # 5to3
        main_A_break, cipos95A, preciseA = break_ops(positionsA, breakA_precise, -limit, median_A)
        main_B_break, cipos95B, preciseB = break_ops(positionsB, breakB_precise, limit, median_B)


    if informative[0].chrA == informative[0].chrB:
        if svtype == "INS":  # use inferred query gap to call svlen
            q_gaps = [i.query_gap for i in informative if i.query_gap != -1]
            if len(q_gaps) > 0:
                svlen = int(np.mean(q_gaps))
            else:
                main_A_break, cipos95A, preciseA, main_B_break, cipos95B, preciseB, svlen = \
                    infer_unmapped_insertion_break_point(main_A_break, cipos95A, preciseA, main_B_break, cipos95B, preciseB)
        else:
            svlen = abs(main_B_break - main_A_break)
    else:
        svlen = 0

    return {"svtype": svtype, "join_type": jointype, "chrA": informative[0].chrA, "chrB": informative[0].chrB,
            "cipos95A": cipos95A, "cipos95B": cipos95B, "posA": main_A_break, "posB": main_B_break,
            "preciseA": preciseA, "preciseB": preciseB,
            "svlen": svlen}


cdef tuple mask_soft_clips(int aflag, int bflag, a_ct, b_ct):

    # Find out which soft clip pairs are compatible with the chosen read pair

    cdef int left_clipA = 1 if (a_ct[0][0] == 4 or a_ct[0][0] == 5) else 0
    cdef int right_clipA = 1 if (a_ct[-1][0] == 4 or a_ct[-1][0] == 5) else 0
    cdef int left_clipB = 1 if (b_ct[0][0] == 4 or b_ct[0][0] == 5) else 0
    cdef int right_clipB = 1 if (b_ct[-1][0] == 4 or b_ct[-1][0] == 5) else 0

    cdef int a_template_start = 0
    cdef int b_template_start = 0

    if aflag & 64 == bflag & 64:  # Same read

        if (left_clipB and right_clipB) or (left_clipA and right_clipA):  # One read has more than one soft-clip

            if aflag & 16:  # A is reverse, convert to forward
                if a_ct[-1][0] != 0:
                    a_template_start = a_ct[-1][1]
            else:
                if a_ct[0][0] != 0:
                    a_template_start = a_ct[0][1]

            if bflag & 16:  # B is reverse
                if b_ct[-1][0] != 0:
                    b_template_start = b_ct[-1][1]
            else:
                if b_ct[0][0] != 0:
                    b_template_start = b_ct[0][1]

            if left_clipB and right_clipB:  # Choose one soft-clip for B

                if b_template_start < a_template_start:
                    if not bflag & 16:  # B on forward strand
                        left_clipB = 0
                    else:
                        right_clipB = 0

                else:
                    if not bflag & 16:  # B on reverse strand
                        right_clipB = 0
                    else:
                        left_clipB = 0

            if left_clipA and right_clipA:  # Choose one soft-clip for A

                if a_template_start < b_template_start:
                    if not aflag & 16:  # A on forward strand
                        left_clipA = 0
                    else:
                        right_clipA = 0

                else:
                    if not aflag & 16:  # A on reverse strand
                        right_clipA = 0
                    else:
                        left_clipA = 0

    else:  # Different reads choose longest if more than one soft-clip
        if left_clipB and right_clipB:
            if b_ct[0][1] > b_ct[-1][1]:
                right_clipB = 0
            else:
                left_clipB = 0

        if left_clipA and right_clipA:
            if a_ct[0][1] > a_ct[-1][1]:
                right_clipA = 0
            else:
                left_clipA = 0

    return left_clipA, right_clipA, left_clipB, right_clipB


cdef query_start_end_from_cigartuples(r):
    # Infer the position on the query sequence of the alignment using cigar string
    cdef int end = 0
    cdef int start = 0
    cdef bint i = 0
    cdef int opp, slen
    for opp, slen in r.cigartuples:
        if opp == 0:
            end += slen
        elif opp == 4 or opp == 5:
            if not i:
                start += slen
                end += slen
                i = 1
            else:
                break
        elif opp == 1:
            end += slen
        i = 1
    return start, end


cdef start_end_query_pair(r1, r2):
    cdef int query_length, s1, e1, s2, e2, start_temp
    # r1 and r2 might be on same read, if this is case infer the query position on the read
    s1, e1 = query_start_end_from_cigartuples(r1)
    s2, e2 = query_start_end_from_cigartuples(r2)
    if r1.flag & 64 == r2.flag & 64:  # same read
        if r2.flag & 16 != r1.flag & 16:  # different strand, count from end
            query_length = r1.infer_read_length()  # Note, this also counts hard-clips
            start_temp = query_length - e2
            e2 = start_temp + e2 - s2
            s2 = start_temp
    return s1, e1, s2, e2


cdef dict call_from_reads(u_reads, v_reads, int insert_size, int insert_stdev):

    grp_u = defaultdict(list)
    grp_v = defaultdict(list)

    for r in u_reads:
        grp_u[r.qname].append(r)
    for r in v_reads:
        grp_v[r.qname].append(r)

    informative = []
    precise_a = []
    precise_b = []

    cdef AlignmentItem v_item, i
    cdef int left_clip_a, right_clip_a, left_clip_b, right_clip_b

    for qname in [k for k in grp_u if k in grp_v]:  # Qname fount on both sides

        u = grp_u[qname]
        v = grp_v[qname]

        if len(u) == 1 and len(v) == 1:
            pair = (u[0], v[0])
        else:
            pair = informative_pair(u, v)

        if pair:

            a, b = pair
            a_ct = a.cigartuples
            b_ct = b.cigartuples

            a_qstart, a_qend, b_qstart, b_qend = start_end_query_pair(a, b)

            # Soft-clips for the chosen pair, plus template start of alignment
            left_clip_a, right_clip_a, left_clip_b, right_clip_b = mask_soft_clips(a.flag, b.flag, a_ct, b_ct)

            # echo(a.pos, a_ct, b.pos, b_ct, left_clip_a, right_clip_a, left_clip_b, right_clip_b)
            v_item = AlignmentItem(a.rname,
                                   b.rname,
                                   int(not a.flag & 2304),  # Is primary
                                   int(not b.flag & 2304),
                                   1 if a.flag & 64 else 2,
                                   1 if b.flag & 64 else 2,
                                   a.pos,
                                   a.reference_end,
                                   b.pos,
                                   b.reference_end,
                                   3 if a.flag & 16 == 0 else 5,
                                   3 if b.flag & 16 == 0 else 5,
                                   left_clip_a,
                                   right_clip_a,
                                   left_clip_b,
                                   right_clip_b,
                                   a_qstart, a_qend, b_qstart, b_qend,
                                   0  # Read overlaps mate, 0 by inference
                                   )

            if v_item.left_clipA and v_item.right_clipA:
                if a_ct[0][1] >= a_ct[-1][1]:
                    v_item.right_clipA = 0
                else:
                    v_item.left_clipA = 0

            if v_item.left_clipB and v_item.right_clipB:
                if b_ct[0][1] >= b_ct[-1][1]:
                    v_item.right_clipB = 0
                else:
                    v_item.left_clipB = 0

            classify_d(v_item)

            if v_item.breakA_precise:
                precise_a.append(v_item.breakA)
            if v_item.breakB_precise:
                precise_b.append(v_item.breakB)

            informative.append(v_item)

    if not informative:
        return {}

    call_informative = Counter([(i.svtype, i.join_type) for i in informative]).most_common()

    cdef str svtype, jointype
    svtype, jointype = call_informative[0][0]

    return make_call(informative, precise_a, precise_b, svtype, jointype, insert_size, insert_stdev)


cdef dict one_edge(infile, u_reads_info, v_reads_info, int clip_length, int insert_size, int insert_stdev,
                   int min_support, int block_edge, int assemble, int extended_tags):

    spanning_alignments = []
    u_reads = []
    v_reads = []
    # echo("hi")
    cdef int cigar_index, event_pos

    for cigar_info, a in u_reads_info:

        u_reads.append(a)
        cigar_index = cigar_info[5]

        if 0 < cigar_index < len(a.cigartuples) - 1:  # Alignment spans SV
            event_pos = cigar_info[6]
            ci = a.cigartuples[cigar_index]
            spanning_alignments.append((ci[0],
                                        a.rname,
                                        event_pos,
                                        event_pos + 1 if ci[0] == 1 else event_pos + a.cigartuples[cigar_index][1] + 1,
                                        event_pos + a.cigartuples[cigar_index][1] + 1,
                                        a))

    for cigar_info, a in v_reads_info:
        v_reads.append(a)

        cigar_index = cigar_info[5]
        if 0 < cigar_index < len(a.cigartuples) - 1:  # Alignment spans SV
            event_pos = cigar_info[6]
            ci = a.cigartuples[cigar_index]
            spanning_alignments.append((ci[0],
                                        a.rname,
                                        event_pos,
                                        event_pos + 1 if ci[0] == 1 else event_pos + a.cigartuples[cigar_index][1] + 1,
                                        event_pos + a.cigartuples[cigar_index][1],
                                        a))

    info = {}
    cdef str svtype, jointype

    if len(spanning_alignments) > 0:
        svtype_m = Counter([i[0] for i in spanning_alignments]).most_common()[0][0]
        spanning_alignments = [i for i in spanning_alignments if i[0] == svtype_m]

    # make call from spanning alignments if possible
    if len(spanning_alignments) > 0:
        posA_arr = [i[2] for i in spanning_alignments]
        posA = int(np.median(posA_arr))
        posA_95 = int(abs(int(np.percentile(posA_arr, [97.5])) - posA))
        posB_arr = [i[3] for i in spanning_alignments]
        posB = int(np.median(posB_arr))
        posB_95 = int(abs(int(np.percentile(posB_arr, [97.5])) - posB))
        chrom = spanning_alignments[0][1]
        svlen = int(np.mean([i[4] for i in spanning_alignments]))
        info.update({"svtype": "DEL" if svtype_m == 2 else "INS",
                     "join_type": "3to5",
                     "chrA": chrom, "chrB": chrom, "posA": posA, "posB": posB, "cipos95A": posA_95, "cipos95B": posB_95,
                     "preciseA": True, "preciseB": True, "svlen": svlen,
                     })
        u_reads = [i[5] for i in spanning_alignments]
        v_reads = []

    else:


        info.update(call_from_reads(u_reads, v_reads, insert_size, insert_stdev))
        if len(info) < 2:
            return {}

    # count read attributes
    attrs = count_attributes(u_reads, v_reads, [i[5] for i in spanning_alignments], min_support, extended_tags,
                             info["svtype"])

    if not attrs or attrs["pe"] + attrs["supp"] + len(spanning_alignments) < min_support:
        return {}

    info.update(attrs)

    as1 = None
    as2 = None
    if assemble:

        if info["preciseA"]:
            as1 = assembler.base_assemble(u_reads, info["posA"], 500)

        if info["preciseB"]:
            as2 = assembler.base_assemble(v_reads, info["posB"], 500)

    info["linked"] = 0
    info["block_edge"] = block_edge
    info["contig"] = None
    info["contig2"] = None
    rbases = 0
    if as1 is not None and "contig" in as1:
        info["contig"] = as1["contig"]
        rbases += as1["ref_bases"]

    if as2 is not None and "contig" in as2:
        info["contig2"] = as2["contig"]
        rbases += as2["ref_bases"]
    info["ref_bases"] = rbases

    return info


cdef list get_reads(infile, nodes_info, buffered_reads, n2n, bint add_to_buffer):

    cdef int j, int_node
    cdef long int p
    cdef uint64_t v
    cdef AlignedSegment a
    aligns = []
    for int_node in nodes_info:

        n = n2n[int_node]
        if int_node in buffered_reads:
            aligns.append((n, buffered_reads[int_node]))
            continue

        p = n[4]
        node = (n[0], n[1], n[2], n[3], p)  # drop cigar index and event pos
        infile.seek(p)

        a = next(infile)
        v = xxhasher(bam_get_qname(a._delegate), len(a.qname), 42)
        if (v, a.flag, a.pos, a.rname, p) == node:
            aligns.append((n, a))
            if add_to_buffer:
                buffered_reads[int_node] = a  # Add to buffer, then block nodes with multi-edges dont need collecting twice
            continue
        else:
            # Try next few reads, not sure why this occurs
            steps = 0
            while steps < 5:  # todo check/optimise this
                # echo("hi")
                a = next(infile)
                steps += 1
                v = xxhasher(bam_get_qname(a._delegate), len(a.qname), 42)
                if (v, a.flag, a.pos, a.rname, p) == node:
                    aligns.append((n, a))
                    if add_to_buffer:
                        buffered_reads[int_node] = a
                    break

    return aligns


cpdef list multi(data, bam, int insert_size, int insert_stdev, int clip_length, int min_support,
                 int assemble_contigs, int extended_tags
                 ):

    # Sometimes partitions are not linked, happens when there is not much support between partitions
    # Then need to decide whether to call from a single partition
    n2n = data["n2n"]
    seen = set(data["parts"].keys())

    out_counts = defaultdict(int)  # The number of 'outward' links to other clusters
    cdef buffered_reads = 0  # Only buffer reads for smallish components, otherwise memory issues
    cdef bint add_to_buffer = 1
    events = []
    for (u, v), d in data["s_between"].items():

        rd_u = get_reads(bam, d[0], data["reads"], data["n2n"], add_to_buffer)   # [(Nodeinfo, alignment)..]
        rd_v = get_reads(bam, d[1], data["reads"], data["n2n"], add_to_buffer)

        buffered_reads += len(rd_u) + len(rd_v)
        if add_to_buffer and buffered_reads > 1e6:
            add_to_buffer = 0

        out_counts[u] += len(rd_u)
        out_counts[v] += len(rd_v)
        if len(rd_u) == 0 or len(rd_v) == 0:
            continue

        if u in seen:
            seen.remove(u)
        if v in seen:
            seen.remove(v)

        events.append(one_edge(bam, rd_u, rd_v, clip_length, insert_size, insert_stdev, min_support, 1, assemble_contigs,
                               extended_tags))

    # Process any unconnected blocks
    if seen:
        for part_key in seen:
            d = data["parts"][part_key]
            if len(d) >= min_support:
                # Call single block, only collect local reads to the block
                rds = get_reads(bam, d, data["reads"], data["n2n"], 0)
                if len(rds) < min_support:
                    continue

                events.append(single(bam, rds, insert_size, insert_stdev, clip_length, min_support, assemble_contigs, extended_tags))

    # Check for events within clustered nodes - happens rarely for paired-end
    for k, d in data["s_within"].items():

        o_count = out_counts[k]
        i_counts = len(d)
        if o_count > 0 and i_counts > (2*min_support) and i_counts > o_count:
            rds = get_reads(bam, d, data["reads"], data["n2n"], 0)
            if len(rds) < min_support:
                continue

            events.append(single(bam, rds, insert_size, insert_stdev, clip_length, min_support,
                                 assemble_contigs, extended_tags))

    return events


cpdef list call_from_block_model(bam, data, clip_length, insert_size, insert_stdev, min_support, extended_tags,
                                 assemble_contigs):
    n_parts = len(data["parts"])
    events = []
    if n_parts >= 1:
        # Processed single edges and break apart connected
        events += multi(data, bam, insert_size, insert_stdev, clip_length, min_support,
                        assemble_contigs, extended_tags)

    elif n_parts == 0: # and min_support == 1:
        # Possible single read only
        rds = get_reads(bam, data["n2n"].keys(), data["reads"], data["n2n"], 0)
        if len(rds) < min_support:
            return []

        e = single(bam, rds, insert_size, insert_stdev, clip_length, min_support,
                   assemble_contigs, extended_tags)
        if e:
            events.append(e)

    return events


cpdef dict get_raw_coverage_information(r, regions, regions_depth, infile):

    # Check if side A in regions
    ar = False  # c_io_funcs.intersecter_int_chrom
    if io_funcs.intersecterpy(regions, r["chrA"], r["posA"], r["posA"] + 1):
        ar = True
    br = False
    if io_funcs.intersecterpy(regions, r["chrB"], r["posB"], r["posB"] + 1):
        br = True

    kind = "extra-regional"
    if not ar and not br:
        if r["chrA"] == r["chrB"] and r["posA"] > r["posB"]:  # Put non-region first
            switch = True

        # Skip if regions have been provided; almost always false positives?
        # if regions is not None:
        #     return None

    switch = False
    if (br and not ar) or (not br and ar):
        kind = "hemi-regional"
        if not br and ar:
            switch = True

    if ar and br:
        if r["chrA"] == r["chrB"]:
            rA = list(regions[r["chrA"]].find_overlap(r["posA"], r["posA"] + 1))[0]
            rB = list(regions[r["chrB"]].find_overlap(r["posB"], r["posB"] + 1))[0]
            if rA[0] == rB[0] and rA[1] == rB[1]:
                kind = "intra_regional"
                # Put posA first
                if r["posA"] > r["posB"]:
                    switch = True
            else:
                kind = "inter-regional"
                if r["chrA"] != sorted([r["chrA"], r["chrB"]])[0]:
                    switch = True
        else:
            kind = "inter-regional"

    if switch:
        chrA, posA, cipos95A, contig2 = r["chrA"], r["posA"], r["cipos95A"], r["contig2"]
        r["chrA"] = r["chrB"]
        r["posA"] = r["posB"]
        r["cipos95A"] = r["cipos95B"]
        r["chrB"] = chrA
        r["posB"] = posA
        r["cipos95B"] = cipos95A
        r["contig2"] = r["contig"]
        r["contig"] = contig2

    if kind == "hemi-regional":
        chrom_i = infile.get_tid(r["chrA"])
        if chrom_i in regions_depth:
            reads_10kb = coverage.calculate_coverage(r["posA"] - 10000, r["posA"] + 10000, regions_depth[chrom_i])
            reads_10kb = round(reads_10kb, 3)
        else:
            reads_10kb = 0
    else:
        # Calculate max
        chrom_i = infile.get_tid(r["chrA"])
        if chrom_i in regions_depth:
            reads_10kb_left = coverage.calculate_coverage(r["posA"] - 10000, r["posA"] + 10000, regions_depth[chrom_i])
            reads_10kb_left = round(reads_10kb_left, 3)
        else:
            reads_10kb_left = 0
        chrom_i = infile.get_tid(r["chrB"])
        if chrom_i in regions_depth:
            reads_10kb_right = coverage.calculate_coverage(r["posB"] - 10000, r["posB"] + 10000, regions_depth[chrom_i])
            reads_10kb_right = round(reads_10kb_right, 3)
        else:
            reads_10kb_right = 0
        if reads_10kb_left > reads_10kb_right:
            reads_10kb = reads_10kb_left
        else:
            reads_10kb = reads_10kb_right

    r["kind"] = kind
    r["raw_reads_10kb"] = reads_10kb
    if r["chrA"] != r["chrB"]:
        r["svlen"] = 1000000
    r["su"] = r["pe"] + r["supp"] + r["spanning"]
    return r
