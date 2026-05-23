import CoreGraphics

struct ProjectSwitcherLayoutMetrics: Equatable {
    let dropdownMaxHeight: CGFloat
    let projectListMaxHeight: CGFloat
    let projectListContentHeight: CGFloat

    var isProjectListScrollable: Bool {
        projectListContentHeight > projectListMaxHeight
    }
}

enum ProjectSwitcherLayout {
    static let maximumScreenHeightFraction: CGFloat = 0.75
    static let estimatedProjectRowHeight: CGFloat = 58
    static let projectRowSpacing: CGFloat = 6

    private static let switchingChromeHeight: CGFloat = 164
    private static let creationChromeHeight: CGFloat = 226

    static func dropdownMaxHeight(for screenHeight: CGFloat) -> CGFloat {
        max(0, screenHeight * maximumScreenHeightFraction)
    }

    static func projectListContentHeight(projectCount: Int) -> CGFloat {
        let count = max(0, projectCount)
        guard count > 0 else { return 0 }
        return CGFloat(count) * estimatedProjectRowHeight + CGFloat(count - 1) * projectRowSpacing
    }

    static func projectListMaxHeight(
        for screenHeight: CGFloat,
        projectCount: Int,
        isCreatingProject: Bool
    ) -> CGFloat {
        let dropdownHeight = dropdownMaxHeight(for: screenHeight)
        let reservedChromeHeight = isCreatingProject ? creationChromeHeight : switchingChromeHeight
        let availableHeight = max(0, dropdownHeight - reservedChromeHeight)
        let contentHeight = projectListContentHeight(projectCount: projectCount)

        guard contentHeight > 0 else { return 0 }
        return min(contentHeight, availableHeight)
    }

    static func metrics(
        screenHeight: CGFloat,
        projectCount: Int,
        isCreatingProject: Bool
    ) -> ProjectSwitcherLayoutMetrics {
        ProjectSwitcherLayoutMetrics(
            dropdownMaxHeight: dropdownMaxHeight(for: screenHeight),
            projectListMaxHeight: projectListMaxHeight(
                for: screenHeight,
                projectCount: projectCount,
                isCreatingProject: isCreatingProject
            ),
            projectListContentHeight: projectListContentHeight(projectCount: projectCount)
        )
    }
}
