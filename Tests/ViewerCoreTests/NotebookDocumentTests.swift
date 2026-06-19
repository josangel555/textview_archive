import XCTest
@testable import ViewerCore

/// Host tests for the nbformat-v4 document model (TSK-717 foundation slice):
/// parse a real corpus, assert structure, mutate cells, serialize, re-parse to
/// the same structure, and confirm round-trip preserves outputs + unknown
/// metadata.
final class NotebookDocumentTests: XCTestCase {

    // A realistic nbformat v4.5 notebook: a markdown cell, a code cell with a
    // mixed output array (stream + execute_result with image data), a raw cell,
    // a kernelspec / language_info envelope, and intentionally UNKNOWN fields
    // (`metadata.custom_unknown`, a cell-level `attachments`) we must not drop.
    private let corpus = """
    {
     "cells": [
      {
       "cell_type": "markdown",
       "id": "abc123",
       "metadata": {
        "tags": [
         "intro"
        ]
       },
       "source": [
        "# Title\\n",
        "\\n",
        "Some **markdown** text."
       ]
      },
      {
       "cell_type": "code",
       "execution_count": 7,
       "id": "def456",
       "metadata": {
        "collapsed": false,
        "scrolled": true
       },
       "outputs": [
        {
         "name": "stdout",
         "output_type": "stream",
         "text": [
          "hello\\n"
         ]
        },
        {
         "data": {
          "image/png": "iVBORw0KGgoAAAANS",
          "text/plain": [
           "<Figure>"
          ]
         },
         "execution_count": 7,
         "metadata": {},
         "output_type": "execute_result"
        }
       ],
       "source": [
        "print('hello')"
       ]
      },
      {
       "cell_type": "raw",
       "id": "ghi789",
       "metadata": {
        "format": "text/latex"
       },
       "source": [
        "\\\\LaTeX raw"
       ]
      }
     ],
     "metadata": {
      "custom_unknown": {
       "nested": [
        1,
        2,
        3
       ]
      },
      "kernelspec": {
       "display_name": "Python 3",
       "language": "python",
       "name": "python3"
      },
      "language_info": {
       "name": "python",
       "version": "3.11.0"
      }
     },
     "nbformat": 4,
     "nbformat_minor": 5
    }
    """

    // MARK: Parse + structure assertions

    func testParsesCellCountAndTypes() throws {
        let doc = try NotebookDocument(jsonText: corpus)
        XCTAssertEqual(doc.cells.count, 3)
        XCTAssertEqual(doc.cells.map(\.cellType), [.markdown, .code, .raw])
        XCTAssertEqual(doc.nbformat, 4)
        XCTAssertEqual(doc.nbformatMinor, 5)
        XCTAssertFalse(doc.isDirty)
    }

    func testParsesCellSource() throws {
        let doc = try NotebookDocument(jsonText: corpus)
        XCTAssertEqual(doc.cells[0].source, "# Title\n\nSome **markdown** text.")
        XCTAssertEqual(doc.cells[1].source, "print('hello')")
        XCTAssertEqual(doc.cells[2].source, "\\LaTeX raw")
    }

    func testParsesIDsAndExecutionCount() throws {
        let doc = try NotebookDocument(jsonText: corpus)
        XCTAssertEqual(doc.cells.map(\.nbformatID), ["abc123", "def456", "ghi789"])
        XCTAssertEqual(doc.cells[1].executionCount, .number(raw: "7"))
        // Non-code cells have no execution_count.
        XCTAssertNil(doc.cells[0].executionCount)
        XCTAssertNil(doc.cells[2].executionCount)
    }

    func testCodeCellOutputsPreserved() throws {
        let doc = try NotebookDocument(jsonText: corpus)
        let outputs = try XCTUnwrap(doc.cells[1].outputs?.arrayElements)
        XCTAssertEqual(outputs.count, 2)
        // The base64 image blob survives opaquely.
        let imageData = outputs[1]["data"]?["image/png"]?.stringValue
        XCTAssertEqual(imageData, "iVBORw0KGgoAAAANS")
        // Markdown / raw cells have no outputs key.
        XCTAssertNil(doc.cells[0].outputs)
        XCTAssertNil(doc.cells[2].outputs)
    }

    // MARK: Round-trip (the load-bearing guarantee)

    func testRoundTripIsByteStable() throws {
        // Parse → serialize → the serialized form is the canonical shape, and
        // serializing AGAIN yields identical bytes (idempotent), which proves
        // the model retains everything it serialized.
        let doc = try NotebookDocument(jsonText: corpus)
        let once = doc.serialized()
        let twice = try NotebookDocument(jsonText: once).serialized()
        XCTAssertEqual(once, twice, "serialize ∘ parse must be idempotent")
    }

    func testRoundTripPreservesUnknownTopLevelMetadata() throws {
        let doc = try NotebookDocument(jsonText: corpus)
        let reparsed = try NotebookDocument(jsonText: doc.serialized())
        // The unknown `custom_unknown` key + kernelspec + language_info survive.
        let original = try JSONValue.parse(corpus)
        let roundTripped = try JSONValue.parse(reparsed.serialized())
        XCTAssertEqual(original["metadata"], roundTripped["metadata"],
                       "top-level metadata (incl. unknown keys) must round-trip")
    }

    func testRoundTripPreservesOutputsByteEquivalently() throws {
        let doc = try NotebookDocument(jsonText: corpus)
        let roundTripped = try JSONValue.parse(doc.serialized())
        let original = try JSONValue.parse(corpus)
        let originalOutputs = original["cells"]?.arrayElements?[1]["outputs"]
        let rtOutputs = roundTripped["cells"]?.arrayElements?[1]["outputs"]
        XCTAssertEqual(originalOutputs, rtOutputs,
                       "code-cell outputs must round-trip byte-equivalently")
    }

    func testUnknownCellFieldRoundTrips() throws {
        // A cell with an unmodeled `attachments` key must survive.
        let withAttachment = """
        {
         "cells": [
          {
           "attachments": {
            "img.png": {
             "image/png": "AAAA"
            }
           },
           "cell_type": "markdown",
           "id": "x",
           "metadata": {},
           "source": [
            "![](attachment:img.png)"
           ]
          }
         ],
         "metadata": {},
         "nbformat": 4,
         "nbformat_minor": 5
        }
        """
        let doc = try NotebookDocument(jsonText: withAttachment)
        let roundTripped = try JSONValue.parse(doc.serialized())
        let original = try JSONValue.parse(withAttachment)
        let originalCell = original["cells"]?.arrayElements?[0]
        let rtCell = roundTripped["cells"]?.arrayElements?[0]
        XCTAssertEqual(originalCell?["attachments"], rtCell?["attachments"])
    }

    // MARK: Cell operations + dirty tracking

    func testInsertCellMarksDirtyAndOrders() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        let new = NotebookCell(cellType: .markdown, source: "inserted")
        doc.insertCell(new, at: 1)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.cells.count, 4)
        XCTAssertEqual(doc.cells[1].source, "inserted")
        XCTAssertEqual(doc.cells[1].id, new.id)
    }

    func testInsertClampsOutOfRangeIndex() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        doc.insertCell(NotebookCell(cellType: .raw, source: "end"), at: 999)
        XCTAssertEqual(doc.cells.last?.source, "end")
        doc.insertCell(NotebookCell(cellType: .raw, source: "start"), at: -5)
        XCTAssertEqual(doc.cells.first?.source, "start")
    }

    func testDeleteCell() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        let id = doc.cells[1].id
        XCTAssertTrue(doc.deleteCell(id: id))
        XCTAssertEqual(doc.cells.count, 2)
        XCTAssertEqual(doc.cells.map(\.cellType), [.markdown, .raw])
        XCTAssertTrue(doc.isDirty)
        // Deleting a missing id is a no-op and doesn't lie about success.
        XCTAssertFalse(doc.deleteCell(id: UUID()))
    }

    func testMoveCell() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        let firstID = doc.cells[0].id
        XCTAssertTrue(doc.moveCell(id: firstID, to: 2))
        XCTAssertEqual(doc.cells.map(\.cellType), [.code, .raw, .markdown])
        XCTAssertEqual(doc.cells[2].id, firstID)
        XCTAssertTrue(doc.isDirty)
    }

    func testEditSource() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        let id = doc.cells[1].id
        XCTAssertTrue(doc.editSource(id: id, to: "print('world')"))
        XCTAssertEqual(doc.cells[1].source, "print('world')")
        XCTAssertTrue(doc.isDirty)
        // No-op edit (same text) doesn't dirty further / returns false.
        var clean = try NotebookDocument(jsonText: corpus)
        XCTAssertFalse(clean.editSource(id: clean.cells[1].id, to: "print('hello')"))
        XCTAssertFalse(clean.isDirty)
    }

    func testEditedSourceSerializesBack() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        doc.editSource(id: doc.cells[1].id, to: "x = 1\ny = 2\n")
        let reparsed = try NotebookDocument(jsonText: doc.serialized())
        XCTAssertEqual(reparsed.cells[1].source, "x = 1\ny = 2\n")
        // Source is stored back in line-array form (each line keeps its \n).
        let cellJSON = try JSONValue.parse(doc.serialized())["cells"]?.arrayElements?[1]
        let sourceLines = cellJSON?["source"]?.arrayElements?.compactMap(\.stringValue)
        XCTAssertEqual(sourceLines, ["x = 1\n", "y = 2\n"])
    }

    func testChangeCellTypeToCodeAddsOutputsScaffold() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        let id = doc.cells[0].id // markdown
        XCTAssertTrue(doc.changeCellType(id: id, to: .code))
        XCTAssertEqual(doc.cells[0].cellType, .code)
        XCTAssertEqual(doc.cells[0].outputs, .array([]))
        XCTAssertEqual(doc.cells[0].executionCount, .null)
        XCTAssertTrue(doc.isDirty)
        // Serializing yields a valid code cell with outputs + execution_count.
        let cellJSON = try JSONValue.parse(doc.serialized())["cells"]?.arrayElements?[0]
        XCTAssertEqual(cellJSON?["cell_type"]?.stringValue, "code")
        XCTAssertNotNil(cellJSON?["outputs"])
        XCTAssertNotNil(cellJSON?["execution_count"])
    }

    func testChangeCellTypeAwayFromCodeDropsOutputs() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        let id = doc.cells[1].id // code
        XCTAssertTrue(doc.changeCellType(id: id, to: .markdown))
        XCTAssertNil(doc.cells[1].outputs)
        XCTAssertNil(doc.cells[1].executionCount)
        let cellJSON = try JSONValue.parse(doc.serialized())["cells"]?.arrayElements?[1]
        XCTAssertNil(cellJSON?["outputs"])
        XCTAssertNil(cellJSON?["execution_count"])
    }

    func testChangeCellTypeNoOpReturnsFalse() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        XCTAssertFalse(doc.changeCellType(id: doc.cells[1].id, to: .code))
        XCTAssertFalse(doc.isDirty)
    }

    func testMarkCleanResetsDirty() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        doc.appendCell(type: .code, source: "1+1")
        XCTAssertTrue(doc.isDirty)
        doc.markClean()
        XCTAssertFalse(doc.isDirty)
    }

    func testAppendedCodeCellHasScaffold() throws {
        var doc = try NotebookDocument(jsonText: corpus)
        let cell = doc.appendCell(type: .code, source: "z = 3")
        XCTAssertEqual(cell.outputs, .array([]))
        XCTAssertEqual(cell.executionCount, .null)
        XCTAssertEqual(doc.cells.last?.id, cell.id)
    }

    // MARK: Source as plain string (nbformat allows string OR array)

    func testParsesStringSourceForm() throws {
        let stringForm = """
        {
         "cells": [
          {
           "cell_type": "code",
           "execution_count": null,
           "metadata": {},
           "outputs": [],
           "source": "single line string"
          }
         ],
         "metadata": {},
         "nbformat": 4,
         "nbformat_minor": 5
        }
        """
        let doc = try NotebookDocument(jsonText: stringForm)
        XCTAssertEqual(doc.cells[0].source, "single line string")
        XCTAssertEqual(doc.cells[0].executionCount, .null)
    }

    // MARK: Error handling

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try NotebookDocument(jsonText: "not json {")) { error in
            XCTAssertEqual(error as? NotebookDocument.LoadError, .notJSON)
        }
    }

    func testRejectsNonObjectRoot() {
        XCTAssertThrowsError(try NotebookDocument(jsonText: "[1,2,3]")) { error in
            XCTAssertEqual(error as? NotebookDocument.LoadError, .notAnObject)
        }
    }

    func testRejectsMissingCells() {
        XCTAssertThrowsError(try NotebookDocument(jsonText: "{\"nbformat\": 4}")) { error in
            XCTAssertEqual(error as? NotebookDocument.LoadError, .missingCells)
        }
    }

    func testRejectsUnknownCellType() {
        let bad = """
        {"cells":[{"cell_type":"sql","metadata":{},"source":[]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """
        XCTAssertThrowsError(try NotebookDocument(jsonText: bad)) { error in
            XCTAssertEqual(error as? NotebookDocument.LoadError, .unsupportedCellType("sql"))
        }
    }
}
