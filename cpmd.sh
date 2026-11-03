#!/usr/bin/env bash

# Author: Marco Marini
# Description: Copy native FLAC comments and pictures without decoding audio.
# License: MIT (see LICENSE)
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
command -v bb >/dev/null 2>&1 || { printf 'Babashka (bb) is required.\n' >&2; exit 1; }
exec bb --file /dev/stdin -- "$@" <<'CLJ'
(require '[babashka.fs :as fs] '[clojure.java.io :as io] '[clojure.string :as str])
(import '(java.io RandomAccessFile DataOutputStream FileInputStream FileOutputStream)
        '(java.nio.file Files StandardCopyOption))

(defn fail [message] (throw (ex-info message {})))
(defn usage []
  (println "Usage: cpmd.sh -s SOURCE -d DESTINATION [-n]")
  (println "Replace FLAC tags and pictures without re-encoding audio; sources are unchanged.")
  (println "Match relative paths and filenames, ignoring extension case and an optional .cdda suffix.")
  (println "Track numbers are never shifted; unmatched destination files are left unchanged.")
  (println "Options: --source/-s, --destination/-d, --dry-run/-n, --help/-h.")
  (println "Requires Babashka (bb)."))

(defn options [arguments]
  (loop [remaining arguments result {}]
    (if-let [arg (first remaining)]
      (cond
        (#{"-h" "--help"} arg) (assoc result :help true)
        (#{"-n" "--dry-run"} arg) (recur (next remaining) (assoc result :dry-run true))
        (#{"-s" "--source" "-d" "--destination"} arg)
        (let [value (second remaining)]
          (when (nil? value) (fail (str "Missing value for " arg)))
          (recur (nnext remaining)
                 (assoc result (if (#{"-s" "--source"} arg) :source :destination) value)))
        :else (fail (str "Unknown argument: " arg)))
      result)))

(defn metadata [path]
  (with-open [stream (RandomAccessFile. (str path) "r")]
    (when-not (= 0x664c6143 (.readInt stream)) (fail (str "Not a native FLAC file: " path)))
    (loop [blocks []]
      (let [header (.readUnsignedByte stream)
            kind (bit-and header 127)
            length (+ (bit-shift-left (.readUnsignedByte stream) 16)
                      (bit-shift-left (.readUnsignedByte stream) 8) (.readUnsignedByte stream))
            data (byte-array length)]
        (when (= kind 127) (fail (str "Invalid FLAC metadata: " path)))
        (.readFully stream data)
        (let [blocks (conj blocks [kind data])]
          (if (bit-test header 7)
            (do
              (when-not (and (= 0 (ffirst blocks)) (= 34 (alength (second (first blocks)))))
                (fail (str "Invalid STREAMINFO: " path)))
              (when (>= (.getFilePointer stream) (.length stream))
                (fail (str "No FLAC audio frames: " path)))
              {:blocks blocks :offset (.getFilePointer stream)})
            (recur blocks)))))))

(defn inventory [root]
  (reduce
   (fn [result path]
     (if (str/ends-with? (str/lower-case (str (fs/file-name path))) ".flac")
       (do
         (when (or (fs/sym-link? path) (not (fs/regular-file? path)))
           (fail (str "Expected a regular FLAC file: " path)))
         (let [relative (fs/relativize root path)
               name (str/replace (str (fs/file-name relative)) #"(?i)(\.cdda)?\.flac$" "")
               key (str (if-let [parent (fs/parent relative)] (fs/path parent name) name))]
           (when (contains? result key) (fail (str "Ambiguous filename: " relative)))
           (assoc result key path)))
       result))
   (sorted-map)
   (rest (tree-seq #(and (fs/directory? %) (not (fs/sym-link? %)))
                   #(sort-by str (fs/list-dir %)) root))))

(defn fingerprint [path]
  (fs/read-attributes path "unix:dev,ino,size,lastModifiedTime,ctime"))

(defn unchanged! [src dst src-state dst-state]
  (when-not (and (= src-state (fingerprint src)) (= dst-state (fingerprint dst)))
    (fail (str "File changed during processing: " src " / " dst))))

(defn copy-metadata! [src dst src-state dst-state]
  (unchanged! src dst src-state dst-state)
  (let [source (metadata src) target (metadata dst)
        blocks (concat (remove #(#{4 6} (first %)) (:blocks target))
                       (filter #(#{4 6} (first %)) (:blocks source)))
        pending (fs/create-temp-file {:dir (fs/parent dst) :prefix ".cpmd." :suffix ".flac"})
        attrs (fs/read-attributes dst "basic:lastModifiedTime,lastAccessTime")]
    (try
      ;; Copy attributes before writing; audio is streamed from the destination.
      (Files/copy dst pending (into-array java.nio.file.CopyOption
                                         [StandardCopyOption/REPLACE_EXISTING StandardCopyOption/COPY_ATTRIBUTES]))
      (with-open [file (FileOutputStream. (str pending))
                  output (DataOutputStream. file)
                  audio (FileInputStream. (str dst))]
        (.writeInt output 0x664c6143)
        (doseq [[index [kind data]] (map-indexed vector blocks)]
          (let [length (alength data)]
            (.writeByte output (bit-or kind (if (= index (dec (count blocks))) 128 0)))
            (.writeByte output (bit-shift-right length 16))
            (.writeByte output (bit-shift-right length 8))
            (.writeByte output length)
            (.write output data)))
        (.position (.getChannel audio) (:offset target))
        (io/copy audio output)
        (.flush output)
        (.force (.getChannel file) true))
      (fs/set-last-modified-time pending (:lastModifiedTime attrs))
      (fs/set-attribute pending "basic:lastAccessTime" (:lastAccessTime attrs))
      (unchanged! src dst src-state dst-state)
      (fs/move pending dst {:replace-existing true :atomic-move true})
      (finally (fs/delete-if-exists pending)))))

(defn run [{:keys [source destination dry-run]}]
  (when-not (and source destination) (fail "Specify -s SOURCE -d DESTINATION."))
  (when-not (and (fs/directory? source) (fs/directory? destination))
    (fail "Source and destination must be directories."))
  (let [source (fs/canonicalize source) destination (fs/canonicalize destination)]
    (when (or (fs/starts-with? source destination) (fs/starts-with? destination source))
      (fail "Source and destination folders must not overlap."))
    (let [sources (inventory source) targets (inventory destination)
          missing (remove #(contains? targets %) (keys sources))]
      (when (empty? sources) (fail "No source FLAC files found."))
      (when (seq missing) (fail (str "Missing destination FLAC files: " (str/join ", " missing))))
      (doseq [[key path] targets :when (not (contains? sources key))]
        (println "[SKIP] No matching source:" (str path)))
      ;; Fully realize preflight before any writes.
      (let [plan (mapv (fn [[key src]]
                         (let [dst (get targets key)
                               src-state (fingerprint src) dst-state (fingerprint dst)]
                           (metadata src) (metadata dst)
                           (when (Files/isSameFile src dst)
                             (fail (str "Source and destination refer to the same file: " dst)))
                           [src dst src-state dst-state])) sources)]
        (doseq [[src dst src-state dst-state] plan]
          (println (str src) "->" (str dst)) (flush)
          (when-not dry-run (copy-metadata! src dst src-state dst-state)))
        (println (if dry-run "Validated" "Updated") (count plan) "FLAC files.")))))

(try
  (let [opts (options *command-line-args*)] (if (:help opts) (usage) (run opts)))
  (catch Exception error
    (binding [*out* *err*] (println "[ERROR]" (.getMessage error)))
    (System/exit 1)))
CLJ
